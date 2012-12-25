#! /usr/bin/perl

# $Id$

use 5.010;
use strict;
use warnings;
use utf8;

use threads;

use Getopt::Long qw{ :config pass_through };

use threads::shared;
use Thread::Queue::Any;

use Thread::Pipeline;

use Encode;
use Encode::Locale;

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

    'mp-threads=i'  => \( my $mp_threads_num = 1 ),

    'update-cfg!'       => \( my $update_cfg = 1 ),
    'skip-dl-src!'      => \my $skip_dl_src,
    'skip-dl-bounds!'   => \my $skip_dl_bounds,
    'skip-img!'         => \my $skip_img_build,
);


my $config_file = shift @ARGV  or usage();

my ( $settings, $regions ) = YAML::LoadFile( $config_file );
if ( $config_file_ftp ) {
    my ($ftp) = YAML::LoadFile( $config_file_ftp );
    $settings->{$_} = $ftp->{$_} // q{}  for qw/ serv auth /;
}

$settings->{today} = strftime( "%Y-%m-%d", localtime );
$settings->{codepage} ||= 1251;
$settings->{encoding} ||= "cp$settings->{codepage}";



my $dirname = "$settings->{prefix}.temp";
rmtree $dirname  if !$continue_mode;
mkdir $_  for grep {!-d} ( $dirname, qw/ _src _bounds _rel / );

my $tt = Template->new( INCLUDE_PATH => "$basedir/templates" );



STDERR->autoflush(1);
STDOUT->autoflush(1);


logg( "Let's the fun begin!" );
logg( "Start building'$settings->{filename}' mapset" );

if ( $settings->{update_config} && $update_cfg ) {
    logg( "Updating configuration" );
    my $cfgdir = $settings->{config};
    $cfgdir =~ s# [/\\] [-\w]+ $ ##xms;
    _qx( svn => "up $cfgdir" );
    logg( "svn info:\n" . _qx( svn => "info $cfgdir" ) );
}



# !!! draft
# Main pipeline

my @blocks = (
    get_osm     => { sub => \&get_osm, },
#    get_bound   => { sub => \&get_bound, },
#    build_mp    => { sub => \&build_mp, num_threads => $mp_threads_num, },
#    build_img   => { sub => \&build_img, },
#    build_mapset=> { sub => \&build_mapset, },

#    upload      => { sub => \&upload },
);

my $pipeline = Thread::Pipeline->new( \@blocks );

for my $reg ( @$regions ) {
    $reg->{mapid} = sprintf "%08d", $settings->{fid}*1000 + $reg->{code};
    $pipeline->enqueue( $reg );
}

$pipeline->no_more_data();

$pipeline->get_results();




# old code

my $q_src = Thread::Queue::Any->new();
my $q_bnd = Thread::Queue::Any->new();
my $q_mp  = Thread::Queue::Any->new();
my $q_img = Thread::Queue::Any->new();
my $q_upl = Thread::Queue::Any->new();

my @reglist :shared;
my $active_mp_threads_num :shared = $mp_threads_num;

=old

my @build_threads = (
    threads->create( \&_source_download_thread ),
    threads->create( \&_boundary_download_thread ),
    ( map { threads->create( \&_mp_build_thread ) } ( 1 .. $mp_threads_num ) ),
    threads->create( \&_img_build_thread ),
);

my $t_upl = threads->create( \&_upload_thread ); 



# Fill queue

REGION:
for my $reg ( @$regions ) {
    $reg->{mapid} = sprintf "%08d", $settings->{fid}*1000 + $reg->{code};
    $q_src->enqueue( $reg );
}
$q_src->enqueue( undef );


# Wait for regions to build
$_->join()  for @build_threads;

$q_upl->enqueue( undef );


if ( !$skip_img_build ) {
    logg( "Indexing whole mapset" );

    chdir $dirname;

    my @files = map {"$_.img"} @reglist;
    my $vars = { settings => $settings, data => { name => $settings->{countryname} }, files => \@files };
    $tt->process('osm_pv.txt.tt2', $vars, 'pv.txt', binmode => ":encoding($settings->{encoding})");

    _qx( cpreview => "pv.txt -m > cpreview.log" );
    logg("Error! Whole mapset - Indexing was not finished due to the cpreview fatal error") unless ($? == 0);

    unlink "OSM.reg";
#    unlink "$_.img.idx" for @reglist;

    cgpsm_run("OSM.mp 2> $devnull", "OSM.img");
    unlink $_ for qw/ OSM.mp OSM.img.idx wine.core /;

    $tt->process('install.bat.tt2', $vars, 'install.bat', binmode => ":crlf");

    if ( $settings->{typ} ) {
        rcopy_glob( "$basedir/$settings->{typ}" => "./osm$settings->{fid}.typ");
        _qx( gmaptool => "-wy $settings->{fid} ./osm$settings->{fid}.typ" );
    }

    ren_lowercase("*.*");

    logg( "Compressing mapset" );

    my $mapdir = "$settings->{filename}_$settings->{today}";
    mkdir $mapdir;
    move $_ => $mapdir  for grep {-f} glob q{*};

    unlink "$basedir/_rel/$settings->{prefix}.$settings->{filename}.7z";
    _qx( arc => "a -y $basedir/_rel/$settings->{prefix}.$settings->{filename}.7z $mapdir" );
    rmtree("$mapdir");

    chdir $basedir;

    if ( $settings->{serv} ) {
        logg( "Uploading mapset" );
        my $auth = $settings->{auth} ? "-u $settings->{auth}" : q{};
        _qx( curl => "--retry 100 $auth -T $basedir/_rel/$settings->{prefix}.$settings->{filename}.7z $settings->{serv}" );
    }
}


rmtree $dirname;

$t_upl->join();

=cut

logg( "That's all, folks!" );


##############################



sub logg {
    my @logs = @_;
    printf STDERR "%s: (%d)  %s\n", strftime("%Y-%m-%d %H:%M:%S", localtime), threads->tid(), "@logs";
    return;
}

sub ren_lowercase {
    my ($mask) = @_;

    move $_ => lc $_  for glob $mask;
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


# !!! cwd!
sub build_img {
    my ($reg) = @_;

    my $regdir = "$reg->{alias}_$settings->{today}";
    mkdir "$dirname/$regdir";
    chdir "$dirname/$regdir";

    move "$basedir/$dirname/$reg->{mapid}.mp" => ".";

    cgpsm_run("ac $reg->{mapid}.mp -e -l > $reg->{mapid}.cgpsmapper.log 2> $devnull","$reg->{mapid}.img");

    if ( $make_house_search ) {
        _qx( housesearch => qq("$reg->{mapid}.mp" > "$reg->{mapid}-s.mp" 2> $devnull) );
        cgpsm_run("ac $reg->{mapid}-s.mp -e -l >> $reg->{mapid}.cgpsmapper.log","$reg->{mapid}.img");
    }

    unlink "$reg->{mapid}.mp";
    unlink "$reg->{mapid}-s.mp"     if $make_house_search;

    if ( -f "$reg->{mapid}.img" ) {
        my $mapid_s = $reg->{mapid} + 10000000;

        logg( "Indexing mapset for '$reg->{alias}'" );
        
        push @reglist, $reg->{mapid};
        push @reglist, $mapid_s   if $make_house_search;

        $reg->{fid} = $settings->{fid} + $reg->{code} // 0;

        my @files = ("$reg->{mapid}.img");
        push @files, "$mapid_s.img"    if $make_house_search;
        my $vars = { settings => $settings, data => $reg, files => \@files };
        $tt->process('osm_pv.txt.tt2', $vars, 'pv.txt', binmode => ":encoding($settings->{encoding})");

        _qx( cpreview => "pv.txt -m > $reg->{mapid}.cpreview.log" );
        logg("Error! Failed to create index for '$reg->{alias}'")  if $?;

        cgpsm_run("OSM.mp 2> $devnull", "OSM.img");

        unlink $_ for qw/ OSM.reg  OSM.mp  OSM.img.idx /;

        $tt->process('install.bat.tt2', $vars, 'install.bat', binmode => ":crlf");

        if ( $settings->{typ} ) {
            rcopy_glob("$basedir/$settings->{typ}" => "./osm$reg->{fid}.typ");
            _qx( gmaptool => "-wy $reg->{fid} ./osm$reg->{fid}.typ" );
        }
                
        ren_lowercase("*.*");
        unlink "wine.core";

        logg( "Compressing mapset '$reg->{alias}'" );

        chdir "$basedir/$dirname";
        rcopy_glob("$regdir/$reg->{mapid}.img*",".");
        rcopy_glob("$regdir/$mapid_s.img*", ".")        if $make_house_search;

        unlink "$basedir/_rel/$settings->{prefix}.$reg->{alias}.7z";
        _qx( arc => "a -y $basedir/_rel/$settings->{prefix}.$reg->{alias}.7z $regdir" );
        rmtree("$regdir");

        $q_upl->enqueue( { 
            code    => $reg->{code},
            alias   => $reg->{alias},
            role    => 'mapset',
            file    => "$basedir/_rel/$settings->{prefix}.$reg->{alias}.7z",
        } );
    }
    else {
        logg( "Error! IMG build failed for '$reg->{alias}'" );
        rcopy_glob("$reg->{mapid}.cgpsmapper.log","$basedir/_logs/$reg->{code}.cgpsmapper." . time() . ".log");
    }

    chdir $basedir;
    return;
}



sub build_mp {
    my ($reg) = @_;

    my $regdir = "$reg->{alias}_$settings->{today}";
    my $regdir_full = "$basedir/$dirname/$regdir";
    mkdir "$regdir_full";

    $reg->{keys} //= q{};

#    $osm2mp =~ s#/#\\#gxms  if $^O =~ /mswin/ix;

    my $osm2mp_params = qq[
        --config $basedir/$settings->{config}
        --mapid $reg->{mapid}
        --mapname "$reg->{name}"
        --bpoly $reg->{poly}
        --defaultcountry $settings->{countrycode}
        --defaultregion "$reg->{name}"
        $settings->{keys}
        $reg->{keys}
    ];

    my $filebase = "$regdir_full/$reg->{mapid}";
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
            $settings->{keys}
            $reg->{keys}
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


    _qx( grep => "ERROR: $filebase.mp > $filebase.errors.log" );
    _qx( log2html => "$filebase.errors.log > $basedir/_rel/$settings->{prefix}.$reg->{alias}.err.htm" );
    $q_upl->enqueue( { 
        code    => $reg->{code},
        alias   => $reg->{alias},
        role    => 'error log',
        file    => "$basedir/_rel/$settings->{prefix}.$reg->{alias}.err.htm",
        delete  => 1,
    } );

    logg( "Compressing MP for '$reg->{alias}'" );
    rmove_glob("$basedir/$dirname/$reg->{mapid}.*", "$regdir_full");
    rcopy_glob("$regdir_full/$reg->{mapid}.mp","$basedir/$dirname");
    unlink "$basedir/_rel/$settings->{prefix}.$reg->{alias}.mp.7z";
    _qx( arc => "a -y $basedir/_rel/$settings->{prefix}.$reg->{alias}.mp.7z $regdir_full" );
    rmtree("$regdir_full");

    $q_upl->enqueue( { 
        code    => $reg->{code},
        alias   => $reg->{alias},
        role    => 'MP',
        file    => "$basedir/_rel/$settings->{prefix}.$reg->{alias}.mp.7z",
    } );

    return; 
} 


##  Thread routines

sub get_osm {
    my ($reg) = @_;

    if ( !defined $reg ) {
        logg( "All sources have been downloaded!" ) if !$skip_dl_src;
        return;
    }

    my $ext = 'osm.pbf';
    $reg->{srcalias} //= $reg->{alias};
    $reg->{srcurl} //= "$settings->{url_base}/$reg->{srcalias}.$ext";
    $reg->{source} = "$basedir/_src/$settings->{prefix}.$reg->{alias}.$ext";

    if ( !$skip_dl_src ) {
        my $filebase = "$basedir/$dirname/$reg->{mapid}";
        if ( -f "$filebase.img"  &&  -f "$filebase.img.idx" ) {
            logg ( "Skip downloading '$reg->{alias} source': img exists" );
        }
        else {
            logg( "Downloading source for '$reg->{alias}'" );
            _qx( wget => "$reg->{srcurl} -O $reg->{source} -o $filebase.wget.log 2> $devnull" );
        }
    }

    return $reg;
}


sub _boundary_download_thread {
    while ( my ($reg) = $q_bnd->dequeue() ) {
        last if !defined $reg;

        $reg->{bound} //= $reg->{alias};
        $reg->{poly} = "$basedir/_bounds/$reg->{bound}.poly";

        if ( !$skip_dl_bounds ) {
            my $filebase = "$basedir/$dirname/$reg->{mapid}";
            if ( -f "$filebase.img"  &&  -f "$filebase.img.idx" ) {
                logg ( "Skip downloading '$reg->{alias}' boundary: img exists" );
            }
            else {
                logg( "Downloading boundary for '$reg->{alias}'" );
                my $onering = $reg->{onering} ? '--onering' : q{};
                _qx( getbound => "-o $reg->{poly} $onering $reg->{bound}  2>  $filebase.getbound.log" );
                logg( "Error! Failed to get boundary for '$reg->{alias}'" )  if $?;
            }
        }

        $q_mp->enqueue( $reg );
    }

    logg( "All boundaries have been downloaded!" ) if !$skip_dl_bounds;
    $q_mp->enqueue( undef )  for ( 1 .. $mp_threads_num );
    return;
}


sub _mp_build_thread {
    while ( my ($reg) = $q_mp->dequeue() ) {
        last if !defined $reg;

        my $filebase = "$basedir/$dirname/$reg->{mapid}";
        if ( -f "$filebase.img"  &&  -f "$filebase.img.idx" ) {
            logg ( "Skip building MP for '$reg->{alias}': already built" );
        }
        else {
            logg ( "Building MP for '$reg->{alias}'" );
            build_mp( $reg );
        }
            
        $q_img->enqueue( $reg );
    }

    $active_mp_threads_num --; 
    if ( !$active_mp_threads_num ) {
        logg( "All MP files have been built!" );
        $q_img->enqueue( undef );
    }

    return;
}    


sub _img_build_thread {
    return if $skip_img_build;

    while ( my ($reg) = $q_img->dequeue() ) {
        last if !defined $reg;

        my $filebase = "$basedir/$dirname/$reg->{mapid}";
        if ( -f "$filebase.img"  &&  -f "$filebase.img.idx" ) {
            logg ( "Skip building IMG for '$reg->{alias}': already built" );

            push @reglist, $reg->{mapid};
            push @reglist, $reg->{mapid} + 10000000   if $make_house_search;
        }
        else {
            logg ( "Building IMG for '$reg->{alias}'" );
            build_img( $reg );
        }
    }

    logg( "All IMG files have been built!" );

    return;
}    


sub _upload_thread {
    return if !$settings->{serv};

    while ( my ($file) = $q_upl->dequeue() ) {
        last if !defined $file;

        logg( "$file->{code} $file->{alias} - uploading $file->{role}" );
        my $auth = $settings->{auth} ? "-u $settings->{auth}" : q{};
        _qx( curl => "--retry 100 $auth -T $file->{file} $settings->{serv} 2> $devnull" );
        unlink $file->{file}  if $file->{delete};
    }

    logg( "All files uploaded!" );
    return;
}



sub usage {
    say "Usage:  ./build_map.pl [--opts] build-config.yml";
    exit;
} 
