#! /usr/local/bin/perl

use 5.010;
use strict;
use warnings;
use utf8;

use threads;
use Thread::Pipeline;

use Carp;
use Encode;
use Encode::Locale;

use Getopt::Long qw{ :config pass_through };

use IO::Handle;
use POSIX qw/ strftime /;
use Cwd qw/ getcwd /; # one from POSIX is not thread-safe!

use YAML;
use Template;

use File::Basename;
use File::Path;
use File::Path::Tiny;
use File::Copy;
use File::Copy::Recursive;
use File::Glob ':bsd_glob';
use Net::SFTP::Foreign;

our $DEBUG = 1;



my $overpass_api = "op_fr";
my $basedir = getcwd();

# external commands required for building
my %CMD = (
    getbound    => "perl $basedir/getbound/getbound.pl -api $overpass_api -singlerequest -aliases $basedir/getbound/etc/osm-getbound-aliases.yml -aliasesdir $basedir/getbound/aliases.d",
    getbrokenrelations => "python $basedir/getbrokenrelations.py --api $overpass_api",
    osmconvert  => "osmconvert -t=$basedir/tmp/osmconvert-temp",
    osm2mp      => "perl $basedir/osm2mp/osm2mp.pl",
    gmapi_builder      => "python $basedir/gmapi-builder.py",
    postprocess => "perl $basedir/osm2mp/mp-postprocess.pl",
    housesearch => "perl $basedir/osm2mp/mp-housesearch.pl",
    log2html    => "perl $basedir/log2html.pl",
    cgpsmapper  => ( $^O eq 'MSWin32' ? 'cgpsmapper' : 'wine cgpsmapper.exe' ),
    gmaptool  => ( $^O eq 'MSWin32' ? 'gmt' : 'wine gmt.exe' ),
    arc         => "7za -bd -w$basedir/tmp",
    bzcat       => 'bzip2 -dcq',
    bzip2       => 'bzip2 -c',
);

my $devnull  = $^O eq 'MSWin32' ? 'nul' : '/dev/null';

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

my ( $settings, $regions, $mapsets ) = YAML::LoadFile( $config_file );

$settings->{today} = strftime( "%Y-%m-%d", localtime );
$settings->{codepage} ||= 1251;
$settings->{encoding} ||= "cp$settings->{codepage}";
$settings->{format} ||= "pbf";

$settings->{config_file_ftp} =   defined($config_file_ftp)   ? $config_file_ftp   : $settings->{config_file_ftp};
$settings->{continue_mode} =     defined($continue_mode)     ? $continue_mode     : $settings->{continue_mode};
$settings->{make_house_search} = defined($make_house_search) ? $make_house_search : $settings->{make_house_search};
if ( defined($mp_threads_num) ){
    $settings->{mp_threads_num} = $mp_threads_num;
}
elsif ( not exists($settings->{mp_threads_num}) ) {
    $settings->{mp_threads_num} = 1;
}
if ( defined($update_cfg) ){
    $settings->{update_cfg}=$update_cfg;
}
elsif ( not exists($settings->{update_cfg}) ) {
    $settings->{update_cfg}=0
}
$settings->{skip_dl_src} =    defined($skip_dl_src)    ? $skip_dl_src    : $settings->{skip_dl_src};
$settings->{skip_dl_bounds} = defined($skip_dl_bounds) ? $skip_dl_bounds : $settings->{skip_dl_bounds};
$settings->{skip_img_build} = defined($skip_img_build) ? $skip_img_build : $settings->{skip_img_build};

if ( $settings->{config_file_ftp} ) {
    my ($ftp) = YAML::LoadFile( $settings->{config_file_ftp} );
    $settings->{$_} = $ftp->{$_} // q{}  for qw/ serv serv_port serv_user serv_password serv_path serv_type /;
}

my $mapset_dir = "$basedir/$settings->{prefix}.$settings->{filename}.temp";
#rmtree $mapset_dir  if !$settings->{continue_mode};
File::Path::Tiny::rm $mapset_dir  if !$settings->{continue_mode};
mkdir $_  for grep {!-d} ( $mapset_dir, qw/ _src _bounds _rel / );

my $tt = Template->new( INCLUDE_PATH => "$basedir/templates" );



STDERR->autoflush(1);
STDOUT->autoflush(1);


logg( "Let the fun begin!" );
logg( "Start building '$settings->{filename}' mapset" );

if ( $settings->{update_cfg} ) {
    logg( "Updating configuration" );
    my $cfgdir = dirname($settings->{config});
    #$cfgdir =~ s# [/\\] [-\w]+ $ ##xms;
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
#    build_mapset => { sub => \&build_mapset, need_finalize => 1 },

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


# Mapsets building pipeline 

my @blocks_mapsets = (
    build_mapset => {
        sub => \&build_mapset,
        post_sub => sub { logg( "Finished mapsets building" )  },
    },

    upload => {
        sub => \&upload,
        post_sub => sub { logg( "All files have been uploaded" ) if $settings->{serv} },
    },
);

if ( !$skip_img_build ) {
    my $pipeline_mapsets = Thread::Pipeline->new( \@blocks_mapsets );
    $pipeline_mapsets->enqueue($_) for @$mapsets;
    $pipeline_mapsets->no_more_data();
    $pipeline_mapsets->get_results();
}

logg( "That's all, folks!" );

#rmtree $mapset_dir;
File::Path::Tiny::rm $mapset_dir;
exit;


##############################



sub logg {
    my @logs = @_;
    if ( $settings->{serv_password} ) {
	s/$settings->{serv_password}/***/g for @logs;
    }
    if ( $settings->{serv_user} ) {
	s/$settings->{serv_user}/***/g for @logs;
    }
    printf STDERR "%s: (%d)  @logs\n", strftime("%Y-%m-%d %H:%M:%S", localtime), threads->tid();
    return;
}


# locale-safe qx
sub _qx {
    my ($cmd, $params) = @_;

    $params =~ s/ \s+ / /gxms;
    $params =~ s/ ^ \s+ | \s+ $ //gxms;

    my $program = $CMD{$cmd} || $cmd;
    logg(encode console_out => "Run: $program $params")  if $DEBUG;
    my $run = encode locale => "$program $params";

    return `$run`;
}



sub cgpsm_run {
    my ($params, $img_file) = @_;

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

    my $skip_gmapi = exists($reg->{skip_gmapi}) ? ($reg->{skip_gmapi}) : ($settings->{skip_gmapi}); 

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
    my $arc_file;
    if ( -f "$reg->{mapid}.img" ) {

        $reg->{fid} = $settings->{fid} + $reg->{code} // 0;
        @files = map {"$_.img"} @imgs;

        if ( !$reg->{skip_mapset} ) {
            $arc_file = _build_mapset( $reg, \@files );

            $pl->enqueue(
                { alias => $reg->{alias}, role => 'IMG', file => $arc_file },
                block => 'upload',
            );
            if ( !${skip_gmapi} ) {
                $arc_file = _build_gmapi( $reg, \@files );

                $pl->enqueue(
                    { alias => $reg->{alias}, role => 'GMAPI', file => $arc_file },
                    block => 'upload',
                );
            }
        }
        File::Path::Tiny::rm( $reg->{path} );
    }
    else {
        logg( "Error! IMG build failed for '$reg->{alias}'" );
        my $cgpsmapper_log="$reg_path/$reg->{mapid}.cgpsmapper.log";
        copy("$cgpsmapper_log","$basedir/_logs/$reg->{code}.cgpsmapper." . time() . ".log") if ( -f "$cgpsmapper_log");
    }

    chdir $start_dir;
    return @files;
}


# !!! chdir!
sub _build_mapset {
    my ($reg, $files) = @_;

    logg( "Indexing mapset '$reg->{alias}'" );

    my $start_dir = getcwd();
    logg( "working dir: " . getcwd() );
    mkdir $reg->{path};

    copy $_ => $reg->{path}  for map {( $_, "$_.idx" )} @$files;

    chdir $reg->{path};
    logg( "working dir: " . getcwd() );

    my $vars = { settings => $settings, data => $reg, files => $files };
    $tt->process('pv.txt.tt2', $vars, 'pv.txt', binmode => ":encoding($settings->{encoding})");

    logg( "working dir: " . getcwd() );
    _qx( cpreview => "pv.txt -m > $reg->{mapid}.cpreview.log" );
    if ($?) {
    logg("Error! Failed to create index for '$reg->{alias}'")  if $?;
    logg( "working dir: " . getcwd() );
    unlink $_ for map {"$start_dir/$_"} @$files;
    unlink $_ for map {"$start_dir/$_.idx"} @$files;
    }

    cgpsm_run("osm.mp 2> $devnull", "osm.img");
    unlink $_ for qw/ osm.reg  osm.mp  osm.img.idx  wine.core /;

    if ( $settings->{typ} ) {
        my $typ = $reg->{typ} = "osm_$reg->{fid}.typ";
        copy "$basedir/$settings->{typ}" => $typ;
        _qx( gmaptool => "-wy $reg->{fid} $typ" );
    }
    my @readme ;
    if ( exists($settings->{readme}) ){
        @readme = ref $settings->{readme} ? @{$settings->{readme}} : ($settings->{readme});
        foreach ( @readme ) {
            copy "$basedir/$_" => ".";
        }
    }

    $tt->process('install.bat.tt2', $vars, 'install.bat', binmode => ":crlf");

    chdir $start_dir;

    logg( "Compressing mapset '$reg->{alias}'" );

    my $arc_file = "$basedir/_rel/$reg->{filename}.7z";
    unlink $arc_file;
    _qx( arc => "a -y $arc_file $reg->{path} >$devnull 2>$devnull" );
    #rmtree( $reg->{path} );
    #File::Path::Tiny::rm( $reg->{path} );

    return $arc_file;
}


sub _build_mp {
    my ($reg, $pl) = @_;

    my $regdir = "$mapset_dir/$reg->{alias}_$settings->{today}";
    mkdir "$regdir";

    my $cat_cmd = 
        $reg->{format} eq 'pbf' ? 'osmconvert' :
        $reg->{format} eq 'o5m' ? 'osmconvert' :
        $reg->{format} eq 'bz2' ? 'bzcat' :
        croak "Unknown format '$reg->{format}'";

    my $cat_params = q{};
    if ( $cat_cmd eq 'osmconvert' ) {
        $cat_params = $reg->{pre_clip}
            ? "-B=\"$reg->{pre_poly}\" --complete-multipolygons --out-osm"
            : "--out-osm";        
    }

    my $osm2mp_params = qq[
        --config $basedir/$settings->{config}
        --codepage $settings->{codepage}
        --mapid $reg->{mapid}
        --mapname "$reg->{name}"
        --bpoly "$reg->{poly}"
        --defaultcountry $settings->{countrycode}
        --defaultregion "$reg->{name}"
        ${ \( $settings->{keys} // q{} ) }
        ${ \( $reg->{keys} // q{} ) }
    ];

    my $filebase = "$regdir/$reg->{mapid}";
    _qx( $cat_cmd => qq[ $cat_params "$reg->{source}"
        | $CMD{osm2mp} $osm2mp_params - -o $filebase.mp
            2> $filebase.osm2mp.log
    ] );

    logg( "Postprocessing MP for '$reg->{alias}'" );
    _qx( postprocess => "$filebase.mp" );

    logg( "Compressing MP for '$reg->{alias}'" );
    move_mask("$mapset_dir/$reg->{mapid}.*","$regdir");
    copy_mask("$regdir/$reg->{mapid}.mp","$mapset_dir");
    copy_mask("$reg->{poly}","$regdir");
    
    my $arc_file = "$basedir/_rel/$settings->{prefix}.$reg->{alias}.mp.7z";
    logg("unlink $arc_file") if $DEBUG;
    unlink $arc_file;
    logg("_qx arc a -y $arc_file $regdir >$devnull 2>$devnull") if $DEBUG;
    _qx( arc => "a -y $arc_file $regdir >$devnull 2>$devnull" );
    #rmtree("$regdir");
    File::Path::Tiny::rm("$regdir");

    if ( exists($reg->{skip_mp_upload})
	? (!$reg->{skip_mp_upload})
	: (!$settings->{skip_mp_upload}) ){
        $pl->enqueue(
            { alias => $reg->{alias}, role => 'MP', file => $arc_file },
            block => 'upload',
        );
    }
    
    return; 
} 

sub _arc_mp {
    my ($alias, $parts, $pl) = @_;

    logg( "Packing mapset '$alias'" );
    my $arcdir = "$mapset_dir/${alias}_$settings->{today}";
    mkdir("$arcdir");
    my $arc_path = "$basedir/_rel/$settings->{prefix}.${alias}.mp.7z";
    logg("unlink $arc_path") if $DEBUG;
    unlink $arc_path;
    
    for my $part (@$parts){
        my $part_path = "$basedir/_rel/$settings->{prefix}.${part}.mp.7z";
        _qx( arc => "e $part_path -y -i!*/*.* -o$arcdir >$devnull 2>$devnull" );
    }
    _qx( arc => "a -y $arc_path $arcdir >$devnull 2>$devnull" );
    logg("remove directory '$arcdir'") if $DEBUG;
    #rmtree("$arcdir");
    File::Path::Tiny::rm("$arcdir");
    
    $pl->enqueue(
        { alias => $alias, role => 'MP', file => $arc_path },
        block => 'upload',
    );

    return;
}

sub _build_gmapi {
    my ($reg, $files) = @_;

    logg( "Building gmapi for '$reg->{alias}'" );

    my $regdir = "$mapset_dir/$reg->{alias}_$settings->{today}";
    my $gmapidir = "$mapset_dir/$reg->{alias}_gmapi_$settings->{today}";
    mkdir "$gmapidir";

    my $files_str = join(' ',  map {"$regdir/$_"} @$files );

    my $gmapi_params = qq[
        -o $gmapidir
        -s $regdir/osm_$reg->{fid}.typ
        -t $regdir/osm.TDB
        -b $regdir/osm.img
        -i $regdir/osm.MDX
        -m $regdir/OSM_MDR.IMG
        -c $settings->{codepage}
        $files_str $regdir/osm.img
    ];

    _qx( $CMD{gmapi_builder} => qq[ $gmapi_params 
        2> $gmapidir/gmapi.log
    ] );
    my $ret_code = $?;
    if ( $ret_code ne 0 ){
        logg("Error! Can't build gmapi for '$reg->{alias}'");
        copy("$gmapidir/gmapi.log","$basedir/_logs/".(exists($reg->{code}) ? ($reg->{code}) : ($reg->{fid})).".gmapi." . time() . ".log") if ( -f "$gmapidir/gmapi.log");
        return;
    }

    my @readme ;
    if ( exists($settings->{readme}) ){
        @readme = ref $settings->{readme} ? @{$settings->{readme}} : ($settings->{readme});
        foreach ( @readme ) {
            copy "$basedir/$_" => "$gmapidir";
        }
    }

    logg( "Compressing gmapi for '$reg->{alias}'" );
    
    my $arc_file = "$basedir/_rel/$settings->{prefix}.$reg->{alias}.gmapi.7z";
    logg("unlink $arc_file") if $DEBUG;
    unlink $arc_file;
    logg("_qx arc a -y $arc_file $gmapidir >$devnull 2>$devnull") if $DEBUG;
    _qx( arc => "a -y $arc_file $gmapidir >$devnull 2>$devnull" );
    #rmtree("$regdir");
    File::Path::Tiny::rm("$gmapidir");
    #File::Path::Tiny::rm("$regdir");

    return $arc_file; 
}

##  Thread workers

sub get_osm {
    my ($reg) = @_;

    state $got = {}; # :shared?
    state $got_fixed = {}; 

    $reg->{format} //= $settings->{format};
    $reg->{srcfilename} //= $settings->{filename};
    $reg->{source} = "$basedir/_src/$reg->{srcfilename}.osm.$reg->{format}";

    my $remote_fn = $reg->{srcalias} // $reg->{alias};
    my $url = $reg->{srcurl} // "$settings->{url_base}/${remote_fn}.osm.$reg->{format}";

    if ( $reg->{fixmultipoly} ) {
        my $source_raw = "$basedir/_src/$reg->{srcfilename}.raw.osm.$reg->{format}";
        # osmconvert do not allow multiple pbf sources
        my $source_broken = "$basedir/_src/$reg->{srcfilename}.broken.osm.o5m";
        my $source_o5m = "$basedir/_src/$reg->{srcfilename}.osm.o5m";
        if ( $got_fixed->{$url} ) {
            logg( "Source for '$reg->{alias}' have already been downloaded" );
            $reg->{format} = 'o5m';
            $reg->{source} = $got_fixed->{$url};
        }
        else {
            if ( !$settings->{skip_dl_src} && !$reg->{skip_build} ) {
                logg( "Downloading source (with fixed multipolygons) for '$reg->{alias}'" );
                my $ret_code = 0;
                _qx( wget => "$url -O $source_raw -o $reg->{filebase}.wget.log 2> $devnull" );
                $ret_code += $?;
                my $cat_cmd = 
                    $reg->{format} eq 'pbf' ? 'osmconvert' :
                    $reg->{format} eq 'o5m' ? 'osmconvert' :
                    $reg->{format} eq 'bz2' ? 'bzcat' :
                    croak "Unknown format '$reg->{format}'";
                my $cat_params = $cat_cmd eq 'osmconvert' ? "--out-osm" : q{};        
                _qx( $cat_cmd => qq[$cat_params "$source_raw"
                    | $CMD{getbrokenrelations} 2> "$reg->{filebase}.getbrokenrelations.log"
                    | $CMD{osmconvert} - -o="$source_broken"] );
                $ret_code += $?;
                _qx( $CMD{osmconvert} => qq[ "$source_raw" "$source_broken" -o="$source_o5m" ] );
                $ret_code += $?;
                logg("Error! Can't download source for $remote_fn") if ( $ret_code ne 0 );
                unlink $source_raw;
                unlink $source_broken;
            }
            $reg->{format} = 'o5m';
            $reg->{source} = "$source_o5m";
            $got_fixed->{$url} = $reg->{source};
            $got->{$url} = $reg->{source};
        }
    }
    else {
        if ( $got->{$url} ) {
            logg( "Source for '$reg->{alias}' have already been downloaded" );
            $reg->{source} = $got->{$url};
            if ( $got_fixed->{$url} ) {
                $reg->{format} = 'o5m';
            }
        }
        else {
            if ( !$settings->{skip_dl_src} && !$reg->{skip_build} ) {
                logg( "Downloading source for '$reg->{alias}'" );
                _qx( wget => "$url -O $reg->{source} -o $reg->{filebase}.wget.log 2> $devnull" );
                my $ret_code = $?;
                logg("Error! Can't download source for $remote_fn") if ( $ret_code ne 0 );
            }
            $got->{$url} = $reg->{source};
        }
    }

    return $reg;
}


sub get_bound {
    my ($reg) = @_;

    $reg->{bound} //= $reg->{alias};
    $reg->{poly} = "$basedir/_bounds/$reg->{bound}.poly";
    $reg->{pre_poly} = "$basedir/_bounds/$reg->{bound}-buf.poly" if $reg->{pre_clip};
    my $srcfile = "$basedir/_bounds/$reg->{bound}.osm";

    return $reg if $settings->{skip_dl_bounds} || $reg->{skip_build};

    logg( "Downloading boundary for '$reg->{alias}'" );
    my $keys = $reg->{onering} ? '--onering' : q{};
    $keys = $reg->{clipbound} ? $keys . ' --clip' : $keys;
    _qx( getbound => "$keys -srcout \"$srcfile\" -o \"$reg->{poly}\" $reg->{bound} 2> $reg->{filebase}.getbound.log" );
    logg( "Error! Failed to get boundary for '$reg->{alias}'" )  if $?;

    if ( $reg->{pre_clip} ) {
        logg( "Creating pre-clip boundary for '$reg->{alias}'" );
        _qx( getbound => "-file \"$srcfile\" -o \"$reg->{pre_poly}\" --offset 0.1 $reg->{bound} 2>> $reg->{filebase}.getbound.log" );
        logg( "Error! Failed to get pre-clip boundary for '$reg->{alias}'" )  if $?;
    }

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

    #return if !@imgs;
    #return \@imgs;
    return;
}


sub build_mapset {
    my ($mapset, $pl) = @_;
    my $house_search= $settings->{make_house_search} && $mapset->{make_house_search} ;
    my $skip_mp_upload = exists($mapset->{skip_mp_upload}) ? ($mapset->{skip_mp_upload}) : ($settings->{skip_mp_upload}); 
    my $skip_gmapi = exists($mapset->{skip_gmapi}) ? ($mapset->{skip_gmapi}) : ($settings->{skip_gmapi}); 

    logg("Mapset '$mapset->{filename}' (@{$mapset->{parts}})");
    _arc_mp($mapset->{filename},\@{$mapset->{parts}}, $pl) unless $skip_mp_upload; 

    logg("Preparing mapset '$mapset->{filename}'");
    my %parts = map { $_ => 1 } @{$mapset->{parts}};
    my @files;
    for my $reg (@$regions){
        if(exists($parts{$reg->{alias}})) { 
            push @files, "$reg->{mapid}.img" if ( -f "$mapset_dir/$reg->{mapid}.img" );
            if ($house_search) {
                my $mapids=$reg->{mapid} + 10000000;
                push @files, "${mapids}.img" if ( -f "$mapset_dir/${mapids}.img" );
            }
        }
    }
    
    my $map_info = {
        name => $mapset->{name},
        alias => $mapset->{filename},
        filename => "$settings->{prefix}.$mapset->{filename}",
        mapid => $mapset->{fid},
        fid => $mapset->{fid},
        path => "$mapset->{filename}_$settings->{today}",
    };

    chdir $mapset_dir;
    my $arc_file;
    if ( scalar @files > 0 ) {

        $arc_file = _build_mapset( $map_info, \@files );
        $pl->enqueue(
            { alias => $mapset->{filename}, role => 'mapset', file => $arc_file },
                block => 'upload',
            );
        if ( !${skip_gmapi} ) {
            $arc_file = _build_gmapi( $map_info, \@files );
            $pl->enqueue(
                { alias => $mapset->{filename}, role => 'GMAPI', file => $arc_file },
                block => 'upload',
            );
        }
        File::Path::Tiny::rm( $map_info->{path} );
    }
    else {
        logg( "Error! Empty mapset '$mapset->{filename}'" );
    }
    chdir $basedir;

    return;
}


sub upload {
    my ($file) = @_;

    return if !$settings->{serv};

    logg( "Uploading $file->{role} for '$file->{alias}'" );
    unless ( defined $file->{file} and -f $file->{file} ){
        logg("Nothing to upload, skip");
        return;
    }
   
    if ( $settings->{serv_type} eq "ftp" ) {
        my $auth = $settings->{serv_user} ? "-u $settings->{serv_user}:$settings->{serv_password}" : q{};
        my $url = "ftp://$settings->{serv}";
        if ( $settings->{serv_port} ) {
            $url = "$url:$settings->{serv_port}";
        }
        if ( $settings->{serv_path} ) {
            $url = "$url/$settings->{serv_path}/";
        }
        _qx( curl => "-sS --retry-connrefused --retry 100 $auth -T $file->{file} $url" );
        unlink $file->{file}  if $file->{delete};
    } 
    elsif ( $settings->{serv_type} eq "sftp" ) {
        my $port=$settings->{serv_port} ? int($settings->{serv_port}) : 22;
        my $sftp = Net::SFTP::Foreign->new(host => $settings->{serv}, user => $settings->{serv_user}, port => $settings->{serv_port}); 
        $sftp->put($file->{file}, $settings->{serv_path}."/".basename($file->{file}));
        if ( int($sftp->error()) != 0 ) {
            logg("SFTP: ".int($sftp->error)." ".$sftp->error);
            logg("Error! Can't upload $file->{file} to $settings->{serv}:$settings->{serv_path}");
        }
        unlink $file->{file}  if $file->{delete};
    }

    return;
}



sub usage {
    say "Usage:  ./build_map.pl [--opts] build-config.yml";
    exit;
}


sub move_mask {
    my ($src_mask,$dst_dir)=@_;
    logg("move_mask $src_mask $dst_dir") if $DEBUG;
    die "move_mask: $dst_dir is not a directory" if (! -d $dst_dir);
    for my $src_file (bsd_glob $src_mask) {
	logg("move_mask $src_file") if $DEBUG;
	move ("$src_file", "$dst_dir") or die $!;
    }
}

sub copy_mask {
    my ($src_mask,$dst_dir)=@_;
    logg("copy_mask $src_mask $dst_dir") if $DEBUG;
    die "copy_mask: $dst_dir is not a directory" if (! -d $dst_dir);
    for my $src_file (bsd_glob $src_mask) {
	logg("copy_mask $src_file") if $DEBUG;
	copy ("$src_file", "$dst_dir") or die $!;
    }
}
