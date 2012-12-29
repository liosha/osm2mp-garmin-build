#! /usr/bin/perl

# $Id$

use 5.010;
use strict;
use warnings;
use utf8;

use threads;
use Thread::Pipeline;

use Encode;
use Encode::Locale;

use Getopt::Long qw{ :config pass_through };

use IO::Handle;
use POSIX;
use YAML;
use Template;

use File::Path;
use File::Copy;
use File::Copy::Recursive;
BEGIN {
    # not exportable in 0.38
    *rcopy_glob = *File::Copy::Recursive::rcopy_glob;
    *rmove_glob = *File::Copy::Recursive::rmove_glob;
}

my $basedir = getcwd();

# external commands required for building
my %CMD = (
    getbound    => "perl $basedir/getbound.pl",
    osmconvert  => 'osmconvert',
    osm2mp      => "perl $basedir/osm2mp/osm2mp.pl",
    postprocess => "perl $basedir/osm2mp/mp-postprocess.pl",
    housesearch => "perl $basedir/osm2mp/mp-housesearch.pl",
    log2html    => "perl $basedir/log2html.pl",
    cgpsmapper  => ( $^O ~~ 'MSWin32' ? 'cgpsmapper' : 'wine cgpsmapper.exe' ),
    gmaptool    => 'gmt',
    arc         => '7za',
);

my $devnull  = $^O ~~ 'MSWin32' ? 'nul' : '/dev/null';

GetOptions(
    'h|help|usage'  => \&usage,

    'upload=s'      => \my $config_file_ftp,
    'continue!'     => \my $continue_mode,

    'house-search!' => \my $make_house_search,

    'mp-threads=i'  => \my $mp_threads_num,

    'update-cfg!'       => \my $update_cfg,
    'skip-dl-src!'      => \my $skip_dl_src,
    'skip-dl-bounds!'   => \my $skip_dl_bounds,
    'skip-img!'         => \my $skip_img_build,
);


my $config_file = shift @ARGV  or usage();

my ( $settings, $regions ) = YAML::LoadFile( $config_file );

$settings->{today} = strftime( "%Y-%m-%d", localtime );
$settings->{codepage} ||= 1251;
$settings->{encoding} ||= "cp$settings->{codepage}";

$settings->{config_file_ftp} = $config_file_ftp || $settings->{config_file_ftp};
$settings->{continue_mode} = $continue_mode || $settings->{continue_mode};
$settings->{make_house_search} = $make_house_search || $settings->{make_house_search};
$settings->{mp_threads_num} = $mp_threads_num || $settings->{mp_threads_num} || 1;
$settings->{update_cfg} = $update_cfg || $settings->{update_cfg} || 1;
$settings->{skip_dl_src} = $skip_dl_src || $settings->{skip_dl_src};
$settings->{skip_dl_bounds} = $skip_dl_bounds || $settings->{skip_dl_bounds};
$settings->{skip_img_build} = $skip_img_build || $settings->{skip_img_build};

if ( $settings->{config_file_ftp} ) {
    my ($ftp) = YAML::LoadFile( $settings->{config_file_ftp} );
    $settings->{$_} = $ftp->{$_} // q{}  for qw/ serv auth /;
}

my $mapset_dir = "$basedir/$settings->{prefix}.temp";
rmtree $mapset_dir  if !$settings->{continue_mode};
mkdir $_  for grep {!-d} ( $mapset_dir, qw/ _src _bounds _rel / );

my $tt = Template->new( INCLUDE_PATH => "$basedir/templates" );



STDERR->autoflush(1);
STDOUT->autoflush(1);


logg( "Let's the fun begin!" );
logg( "Start building '$settings->{filename}' mapset" );

if ( $settings->{update_config} ) {
    logg( "Updating configuration" );
    my $cfgdir = $settings->{config};
    $cfgdir =~ s# [/\\] [-\w]+ $ ##xms;
    _qx( svn => "up $cfgdir" );
    logg( "svn info:\n" . _qx( svn => "info $cfgdir" ) );
}



# Main pipeline

my @blocks = (
    get_osm => {
        sub => \&get_osm,
        post_sub => sub { logg( "All source files have been downloaded" ) if !$settings->{skip_dl_src} },
    },
    get_bound => {
        sub => \&get_bound,
        post_sub => sub { logg( "All boundaries have been downloaded" ) if !$settings->{skip_dl_bounds} },
    },
    build_mp => {
        sub => \&build_mp,
        num_threads => $settings->{mp_threads_num},
        post_sub => sub { logg( "Finished MP building" ) },
    },
    build_img => {
        sub => \&build_img,
        post_sub => sub { logg( "Finished IMG building" ) if !$settings->{skip_img_build} },
    },
    build_mapset => { sub => \&build_mapset, need_finalize => 1 },

    upload => {
        sub => \&upload,
        post_sub => sub { logg( "All files have been uploaded" ) if $settings->{serv} },
    },
);

my $pipeline = Thread::Pipeline->new( \@blocks );

for my $reg ( @$regions ) {
    $reg->{mapid}       = sprintf "%08d", $settings->{fid}*1000 + $reg->{code};
    $reg->{filebase}    = "$mapset_dir/$reg->{mapid}";
    $reg->{filename}    //= "$settings->{prefix}.$reg->{alias}";

    $reg->{skip_build} = -f "$reg->{filebase}.img" && -f "$reg->{filebase}.img.idx";
    logg( "Skip building '$reg->{alias}': img exists" ) if $reg->{skip_build};

    $pipeline->enqueue( $reg );
}

$pipeline->no_more_data();

$pipeline->get_results();


logg( "That's all, folks!" );

rmtree $mapset_dir;
exit;


##############################



sub logg {
    my @logs = @_;
    printf STDERR "%s: (%d)  @logs\n", strftime("%Y-%m-%d %H:%M:%S", localtime), threads->tid();
    return;
}


# locale-safe qx
sub _qx {
    my ($cmd, $params) = @_;

    $params =~ s/ \s+ / /gxms;
    $params =~ s/ ^ \s+ | \s+ $ //gxms;

    my $program = $CMD{$cmd} || $cmd;
    my $run = encode locale => "$program $params";

    return `$run`;
}



sub cgpsm_run {
    my ($params, $img_file) = @_;

    logg("Run 'cgpsmapper $params'");

    my $max_retry = 5;
    for my $try ( 1 .. $max_retry ) {
        _qx( cgpsmapper => $params );
 
        my $ret_code = $?;
        $ret_code ||= 9999  if !-f $img_file;

        logg("Cgpsmapper returns '$ret_code'");

        last if !$ret_code || $try == $max_retry;

        logg("Do some sleep");
        sleep 30;
    }

    return;
}


# !!! chdir!
sub _build_img {
    my ($reg, $pl) = @_;

    my $start_dir = getcwd();
    chdir $mapset_dir;

    my $reg_path = $reg->{path} = "$mapset_dir/$reg->{alias}_$settings->{today}";
    mkdir $reg_path;

    my $mp_file = "$reg->{mapid}.mp";
    cgpsm_run("ac $mp_file -e -l > $reg_path/$reg->{mapid}.cgpsmapper.log 2> $devnull", "$reg->{mapid}.img");
    my @imgs = ( $reg->{mapid} );

    if ( $settings->{make_house_search} ) {
        my $smp_file = "$reg->{mapid}-s.mp";
        _qx( housesearch => "$mp_file > $smp_file 2> $devnull" );
        my $mapids=$reg->{mapid} + 10000000;
        cgpsm_run("ac $smp_file -e -l >> $reg_path/$reg->{mapid}-s.cgpsmapper.log 2> $devnull", "${mapids}.img");
        unlink $smp_file;
        if ( -f "${mapids}.img" ) { push @imgs, ${mapids}; }
        else { logg( "Warning! Housesearch IMG build failed for '$reg->{alias}'" ); }
    }

    unlink $mp_file;

    my @files;
    if ( -f "$reg->{mapid}.img" ) {

        $reg->{fid} = $settings->{fid} + $reg->{code} // 0;
        @files = map {"$_.img"} @imgs;

        my $arc_file = _build_mapset( $reg, \@files );

        $pl->enqueue(
            { alias => $reg->{alias}, role => 'IMG', file => $arc_file },
            block => 'upload',
        );
    }
    else {
        logg( "Error! IMG build failed for '$reg->{alias}'" );
        rcopy_glob("$reg->{mapid}.cgpsmapper.log","$basedir/_logs/$reg->{code}.cgpsmapper." . time() . ".log");
    }

    chdir $start_dir;
    return @files;
}


# !!! chdir!
sub _build_mapset {
    my ($reg, $files) = @_;

    logg( "Indexing mapset '$reg->{alias}'" );

    my $start_dir = getcwd();
    mkdir $reg->{path};

    copy $_ => $reg->{path}  for map {( $_, "$_.idx" )} @$files;

    chdir $reg->{path};

    my $vars = { settings => $settings, data => $reg, files => $files };
    $tt->process('pv.txt.tt2', $vars, 'pv.txt', binmode => ":encoding($settings->{encoding})");

    _qx( cpreview => "pv.txt -m > $reg->{mapid}.cpreview.log" );
    logg("Error! Failed to create index for '$reg->{alias}'")  if $?;

    cgpsm_run("osm.mp 2> $devnull", "osm.img");
    unlink $_ for qw/ osm.reg  osm.mp  osm.img.idx  wine.core /;

    if ( $settings->{typ} ) {
        my $typ = $reg->{typ} = "osm_$reg->{fid}.typ";
        copy "$basedir/$settings->{typ}" => $typ;
        _qx( gmaptool => "-wy $reg->{fid} $typ" );
    }

    $tt->process('install.bat.tt2', $vars, 'install.bat', binmode => ":crlf");

    chdir $start_dir;

    logg( "Compressing mapset '$reg->{alias}'" );

    my $arc_file = "$basedir/_rel/$reg->{filename}.7z";
    unlink $arc_file;
    _qx( arc => "a -y $arc_file $reg->{path}" );
    rmtree( $reg->{path} );

    return $arc_file;
}


sub _build_mp {
    my ($reg, $pl) = @_;

    my $regdir = "$mapset_dir/$reg->{alias}_$settings->{today}";
    mkdir "$regdir";

    my $osm2mp_params = qq[
        --config $basedir/$settings->{config}
        --mapid $reg->{mapid}
        --mapname "$reg->{name}"
        --bpoly $reg->{poly}
        --defaultcountry $settings->{countrycode}
        --defaultregion "$reg->{name}"
        ${ \( $settings->{keys} // q{} ) }
        ${ \( $reg->{keys} // q{} ) }
    ];

    my $filebase = "$regdir/$reg->{mapid}";
    _qx( osmconvert => qq[ "$reg->{source}" --out-osm
        | $CMD{osm2mp} $osm2mp_params - -o $filebase.mp
            2> $filebase.osm2mp.log
    ] );

    if ( $reg->{fixmultipoly} ) {
        logg( "Repairing broken multipolygons for '$reg->{alias}'" );
        my $cmd_brokenmpoly = qq[
            $CMD{osm2mp}
            --config $basedir/$settings->{config_brokenmpoly}
            --bpoly $reg->{poly}
            --defaultcountry $settings->{countrycode}
            --defaultregion "$reg->{name}"
            ${ \( $settings->{keys} // q{} ) }
            ${ \( $reg->{keys} // q{} ) }
        ];
        _qx( osmconvert => qq[ "$reg->{source}" --out-osm
            | $basedir/getbrokenrelations.py
                2> "$filebase.getbrokenrelations.log"
            | $cmd_brokenmpoly -
                >> "$filebase.mp"
                2> "$filebase.osm2mp.broken.log"
        ] );
    }

    logg( "Postprocessing MP for '$reg->{alias}'" );
    _qx( postprocess => "$filebase.mp" );


    if (1) {
        my $err_file = "$basedir/_rel/$settings->{prefix}.$reg->{alias}.err.htm";
        _qx( grep => "ERROR: $filebase.mp > $filebase.errors.log" );
        _qx( log2html => "$filebase.errors.log > $err_file" );

        $pl->enqueue(
            { alias => $reg->{alias}, role => 'error log', file => $err_file, delete  => 1 },
            block => 'upload',
        );
    }

    logg( "Compressing MP for '$reg->{alias}'" );
    rmove_glob("$mapset_dir/$reg->{mapid}.*" => $regdir);
    rcopy_glob("$regdir/$reg->{mapid}.mp" => $mapset_dir);

    my $arc_file = "$basedir/_rel/$settings->{prefix}.$reg->{alias}.mp.7z";
    unlink $arc_file;
    _qx( arc => "a -y $arc_file $regdir" );
    rmtree("$regdir");

    $pl->enqueue(
        { alias => $reg->{alias}, role => 'MP', file => $arc_file },
        block => 'upload',
    );
    
    return; 
} 


##  Thread workers

sub get_osm {
    my ($reg) = @_;

    $reg->{source} = "$basedir/_src/$reg->{filename}.osm.pbf";

    return $reg if $settings->{skip_dl_src} || $reg->{skip_build};

    logg( "Downloading source for '$reg->{alias}'" );
    my $remote_fn = $reg->{srcalias} // $reg->{alias};
    my $url = $reg->{srcurl} // "$settings->{url_base}/${remote_fn}.osm.pbf";
    _qx( wget => "$url -O $reg->{source} -o $reg->{filebase}.wget.log 2> $devnull" );

    return $reg;
}


sub get_bound {
    my ($reg) = @_;

    $reg->{bound} //= $reg->{alias};
    $reg->{poly} = "$basedir/_bounds/$reg->{bound}.poly";

    return $reg if $settings->{skip_dl_bounds} || $reg->{skip_build};

    logg( "Downloading boundary for '$reg->{alias}'" );
    my $keys = $reg->{onering} ? '--onering' : q{};
    _qx( getbound => "$keys -o $reg->{poly} $reg->{bound} 2> $reg->{filebase}.getbound.log" );
    logg( "Error! Failed to get boundary for '$reg->{alias}'" )  if $?;

    return $reg;
}


sub build_mp {
    my ($reg, $pl) = @_;

    return $reg if $reg->{skip_build};

    logg ( "Building MP for '$reg->{alias}'" );
    _build_mp( $reg, $pl );

    return $reg;
}


sub build_img {
    my ($reg, $pl) = @_;

    return if $settings->{skip_img_build};

    my @imgs;
    if ( $reg->{skip_build} ) {
        @imgs = ($reg->{mapid});
        push @imgs, $reg->{mapid} + 10000000   if $settings->{make_house_search};
    }
    else {
        logg ( "Building IMG for '$reg->{alias}'" );
        @imgs = _build_img( $reg, $pl );
    }

    return if !@imgs;
    return \@imgs;
}


sub build_mapset {
    my ($add_files) = @_;
    state $files = [];

    if ( $add_files ) {
        push @$files, @$add_files;
        return;
    }

    return if !@$files;

    my $map_info = {
        name => $settings->{countryname},
        alias => $settings->{filename},
        filename => $settings->{filename},
        mapid => $settings->{fid},
        fid => $settings->{fid},
        path => "$settings->{filename}_$settings->{today}",
    };

    chdir $mapset_dir;
    my $arc_file = _build_mapset( $map_info, $files );
    chdir $basedir;

    return { alias => $settings->{filename}, role => 'main mapset', file => $arc_file };
}


sub upload {
    my ($file) = @_;

    return if !$settings->{serv};

    logg( "Uploading $file->{role} for '$file->{alias}'" );
    
    my $auth = $settings->{auth} ? "-u $settings->{auth}" : q{};
    _qx( curl => "--retry 100 $auth -T $file->{file} $settings->{serv} 2> $devnull" );
    unlink $file->{file}  if $file->{delete};

    return;
}



sub usage {
    say "Usage:  ./build_map.pl [--opts] build-config.yml";
    exit;
}


