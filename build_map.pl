#! /usr/bin/perl

# $Id$

use strict;
use uni::perl;

use Getopt::Long qw{ :config pass_through };

use threads;
use threads::shared;
use Thread::Queue::Any;

use IO::Handle;
use POSIX;
use Encode;
use YAML;
use File::Copy;
use File::Path;

use Template;

use File::Copy::Recursive;
BEGIN {
    # not exportable in 0.38
    *rcopy_glob = *File::Copy::Recursive::rcopy_glob;
    *rmove_glob = *File::Copy::Recursive::rmove_glob;
}


STDERR->autoflush(1);
STDOUT->autoflush(1);


my $config_file = 'test.yml';
GetOptions( 'c|config=s' => \$config_file );

my ( $settings, $regions ) = YAML::LoadFile( $config_file );

GetOptions(
    'upload=s'      => \my $config_file_ftp,
    'continue!'     => \my $continue_mode,

    'house-search!' => \my $make_house_search,

    'mp-threads=i'  => \( my $mp_threads_num = 2 ),

    'update-cfg!'       => \( my $update_cfg = 1 ),
    'skip-dl-src!'      => \my $skip_dl_src,
    'skip-dl-bounds!'   => \my $skip_dl_bounds,
);


if ( $config_file_ftp ) {
    my ($ftp) = YAML::LoadFile( $config_file_ftp );
    $settings->{$_} = $ftp->{$_} // q{}  for qw/ serv auth /;
}

$settings->{today} = strftime( "%Y-%m-%d", localtime );
$settings->{codepage} ||= 1251;
$settings->{encoding} = "cp$settings->{codepage}";


my $devnull  = $^O ~~ 'MSWin32' ? 'nul' : '/dev/null';

my $basedir = getcwd();
my $dirname = "$settings->{prefix}.temp";
rmtree $dirname  if !$continue_mode;
mkdir $dirname  for grep {!-d} ( $dirname, qw/ _src _bounds _rel / );

my $tt = Template->new( INCLUDE_PATH => "$basedir/templates" );

my @reglist :shared;




my $noupload :shared = 0; # do not upload to server flag


my $prefix  :shared = exists($settings->{prefix})     ?  $settings->{prefix}        :  'test';
my $cfgfile :shared = exists($settings->{config})     ?  $settings->{config}        :  'garmin.yml';
my $cfgfile_brokenmpoly :shared = exists($settings->{config_brokenmpoly})     ?  $settings->{config_brokenmpoly}        :  'garmin.yml';
my $fidbase :shared = exists($settings->{fid})        ?  $settings->{fid}           :  100;;
my $countrycode = exists($settings->{countrycode})    ?  $settings->{countrycode}   :  'test';
my $countryname = exists($settings->{countryname})    ?  $settings->{countryname}   :  'test';
my $filename    = exists($settings->{filename})       ?  $settings->{filename}      :  'test';
my $common_keys :shared = $settings->{keys} // q{};
my $name_postfix :shared = exists($settings->{name_postfix}) ? "$settings->{filename} " : q{};



my $q_src :shared = Thread::Queue::Any->new();
my $q_bnd :shared = Thread::Queue::Any->new();
my $q_mp  :shared = Thread::Queue::Any->new();
my $q_img :shared = Thread::Queue::Any->new();
my $q_upl :shared = Thread::Queue::Any->new();




logg( "Let's the fun begin!" );
logg( "Start building'$settings->{filename}' mapset" );

if ( $update_cfg ) {
    logg( "Updating configuration" );
    `svn up open-cfg`;
    logg( "svn info:\n" . `svn info open-cfg` );
    rcopy_glob("open-cfg/osm.typ","osm.typ");
}


# Initializing thread pipeline

my $active_mp_threads_num :shared = $mp_threads_num;

my @build_threads = (
    threads->create( \&_source_download_thread ),
    threads->create( \&_boundary_download_thread ),
    ( map { threads->create( \&_mp_build_thread ) } ( 1 .. $mp_threads_num ) ),
# img
);

my $t_upl = threads->create( \&_upload_thread ); 



# IMG building thread
my $t_bld_img = threads->create( sub {
    while ( my ($reg) = $q_img->dequeue() ) {
        if ( defined $reg ) {
            if ( -f "$dirname/$reg->{mapid}.img"  &&  -f "$dirname/$reg->{mapid}.img.idx"  ) {
                logg( "$reg->{code} $reg->{alias} - IMG already built" );

                push @reglist, $reg->{mapid};
                push @reglist, $reg->{mapid} + 10000000         if $make_house_search;

                next;
            }

            logg( "$reg->{code} $reg->{alias} - compiling IMG" );
            my $regdir = "$reg->{alias}_$settings->{today}";
            mkdir "$dirname/$regdir";
            chdir "$dirname/$regdir";
            move("$basedir/$dirname/$reg->{mapid}.mp",".");

            cgpsm_run("ac $reg->{mapid}.mp -e -l > $reg->{mapid}.cgpsmapper.log 2> $devnull","$reg->{mapid}.img");
            if ( $make_house_search ) {
                `$basedir/osm2mp/mp-housesearch.pl "$reg->{mapid}.mp" > "$reg->{mapid}-s.mp" 2> $devnull`;
                cgpsm_run("ac $reg->{mapid}-s.mp -e -l >> $reg->{mapid}.cgpsmapper.log","$reg->{mapid}.img");
            }
            my $smp = $reg->{mapid} + 10000000;

            unlink "$reg->{mapid}.mp";
            unlink "$reg->{mapid}-s.mp"     if $make_house_search;

            if ( -f "$reg->{mapid}.img" ) {
                logg( "$reg->{code} $reg->{alias} - indexing mapset" );
                push @reglist, $reg->{mapid};
                push @reglist, $smp         if $make_house_search;

                $reg->{fid} = $settings->{fid} + $reg->{code} // 0;

                my @files = ("$reg->{mapid}.img");
                push @files, "$smp.img"    if $make_house_search;
                my $vars = { settings => $settings, data => $reg, files => \@files };
                $tt->process('osm_pv.txt.tt2', $vars, 'pv.txt', binmode => ":encoding($settings->{encoding})");

                `cpreview pv.txt -m > $reg->{mapid}.cpreview.log`;
                logg("Error! $reg->{code} $reg->{alias} - Indexing was not finished due to the cpreview fatal error") unless ($? == 0);

                unlink 'OSM.reg';
                cgpsm_run("OSM.mp 2> $devnull", "OSM.img");

                unlink 'OSM.mp';
                unlink 'OSM.img.idx';

                $tt->process('install.bat.tt2', $vars, 'install.bat', binmode => ":crlf");


                rcopy_glob("$basedir/osm.typ","./osm$reg->{fid}.typ");
                `gmt -wy $reg->{fid} ./osm$reg->{fid}.typ`;
                
                ren_lowercase("*.*");
                unlink "wine.core";

                logg( "$reg->{code} $reg->{alias} - compressing mapset" );

                chdir "$basedir/$dirname";
                rcopy_glob("$regdir/$reg->{mapid}.img*",".");
                rcopy_glob("$regdir/$smp.img*", ".")        if $make_house_search;
                unlink "$basedir/_rel/$prefix.$reg->{alias}.7z";
                `7za a -y $basedir/_rel/$prefix.$reg->{alias}.7z $regdir`;
                rmtree("$regdir");

                $q_upl->enqueue( { 
                    code    => $reg->{code},
                    alias   => $reg->{alias},
                    role    => 'mapset',
                    file    => "$basedir/_rel/$prefix.$reg->{alias}.7z",
                } );
            }
            else {
                logg( "Error! $reg->{code} $reg->{alias} - IMG build failed, skipping" );
                rcopy_glob("$reg->{mapid}.cgpsmapper.log","$basedir/_logs/$reg->{code}.cgpsmapper." . time() . ".log");
            }

            chdir $basedir;
        };

        unless ( defined $reg ) {
            logg( "All maps has been built!" );
            return;
        }
    }
} );
logg( "IMG building thread created" );





# Start!

REGION:
for my $reg ( @$regions ) {
    $reg->{mapid} = sprintf "%08d", $fidbase*1000 + $reg->{code};
    $q_src->enqueue( $reg );
}

$q_src->enqueue( undef );

# wait for regions to build

$_->join()  for @build_threads;

$t_bld_img->join();

$q_upl->enqueue( undef );



logg( "Indexing whole mapset" );

chdir $dirname;

my @files = map {"$_.img"} @reglist;
my $vars = { settings => $settings, data => { name => $countryname }, files => \@files };
$tt->process('osm_pv.txt.tt2', $vars, 'pv.txt', binmode => ":encoding($settings->{encoding})");


`cpreview pv.txt -m > cpreview.log`;
logg("Error! Whole mapset - Indexing was not finished due to the cpreview fatal error") unless ($? == 0);

unlink "OSM.reg";
for my $mp (@reglist) {
#    unlink "$mp.img.idx";
}

cgpsm_run("OSM.mp 2> $devnull", "OSM.img");

unlink 'OSM.mp';
unlink 'OSM.img.idx';
unlink "wine.core";

$tt->process('install.bat.tt2', $vars, 'install.bat', binmode => ":crlf");

rcopy_glob("../osm.typ","./osm${fidbase}.typ");
`gmt -wy $fidbase ./osm${fidbase}.typ`;

ren_lowercase("*.*");

logg( "Compressing mapset" );

my $mapdir = "${filename}_$settings->{today}";
mkdir $mapdir;
move $_ => $mapdir  for grep {-f} glob q{*};

unlink "$basedir/_rel/$prefix.$filename.7z";
`7za a -y $basedir/_rel/$prefix.$filename.7z $mapdir`;
rmtree("$mapdir");

chdir $basedir;


if ( $settings->{serv} ) {
    logg( "Uploading mapset" );
    my $auth = $settings->{auth} ? "-u $settings->{auth}" : q{};
    `curl --retry 100 $auth -T $basedir/_rel/$prefix.$filename.7z $settings->{serv}`;
}

rmtree("$dirname");


$t_upl->join();
logg( "That's all, folks!" );


##############################



sub logg {
    printf STDERR "%s: (%d)  %s\n", strftime("%Y-%m-%d %H:%M:%S", localtime), threads->tid(), @_;
}

sub ren_lowercase {

    my $mask= $_[0];
    my @filelist=glob($mask);
    foreach (@filelist) {
        move($_,lc($_)) ;
    }
}

sub cgpsm_run {
        logg("cgpsmapper @_");
        my $ret_code = 1;
        my $num = 1;

        my $cmd = $^O ? 'cgpsmapper' : 'wine cgpsmapper.exe';

        while ($ret_code != 0 && $num<=5){
            `$cmd $_[0]`;
            $ret_code = $?;

            if ( ($ret_code == 0) && (! -f "$_[1]") ) {
            $ret_code=9999;
            }
            logg("cgpsmapper exit($ret_code)");
            if ($ret_code != 0) {
            sleep(60);
            }
            $num++;
        }
}


sub build_mp {
    my ($reg) = @_;

    my $regdir = "$reg->{alias}_$settings->{today}";
    my $regdir_full = "$basedir/$dirname/$regdir";
    mkdir "$regdir_full";
    $reg->{keys} = q{} unless exists $reg->{keys};

    my $osm2mp = "$basedir/osm2mp/osm2mp.pl";
    $osm2mp =~ s#/#\\#gxms  if $^O =~ /mswin/ix;

    my $cmd =  qq{ 
        perl $osm2mp
        --config $basedir/$cfgfile
        --mapid $reg->{mapid}
        --mapname "$reg->{name}"
        --bpoly $reg->{poly}
        --defaultcountry $countrycode
        --defaultregion "$reg->{name}"
        $common_keys
        $reg->{keys}
        -
    };
    $cmd =~ s/\s+/ /g;

    `osmconvert "$reg->{source}" --out-osm | $cmd >"$regdir_full/$reg->{mapid}.mp" 2>"$regdir_full/$reg->{mapid}.osm2mp.log"`;
    if (exists $reg->{fixmultipoly} && $reg->{fixmultipoly}=="yes"){
        logg( "$reg->{code} $reg->{alias} - converting broken multipolygons to MP" );
        my $cmd_brokenmpoly = qq{ 
            perl $osm2mp
            --config $basedir/$cfgfile_brokenmpoly
            --mapid $reg->{mapid}
            --mapname "$reg->{name}"
            --bpoly $reg->{poly}
            --defaultcountry $countrycode
            --defaultregion "$reg->{name}"
            $common_keys
            $reg->{keys}
            -
        };
        $cmd_brokenmpoly =~ s/\s+/ /g;
        `osmconvert "$reg->{source}" --out-osm | $basedir/getbrokenrelations.py 2>"$basedir/$dirname/$reg->{mapid}.getbrokenrelations.log" | $cmd_brokenmpoly >>"$regdir_full/$reg->{mapid}.mp" 2>"$regdir_full/$reg->{mapid}.osm2mp.broken.log"`;
    }
    logg( "$reg->{code} $reg->{alias} - MP postprocess" );
    `$basedir/osm2mp/mp-postprocess.pl "$regdir_full/$reg->{mapid}.mp"`;

    `grep ERROR: $regdir_full/$reg->{mapid}.mp > $regdir_full/$reg->{mapid}.errors.log`;
    `$basedir/log2html.pl $regdir_full/$reg->{mapid}.errors.log > $basedir/_rel/$prefix.$reg->{alias}.err.htm`;
    $q_upl->enqueue( { 
        code    => $reg->{code},
        alias   => $reg->{alias},
        role    => 'error log',
        file    => "$basedir/_rel/$prefix.$reg->{alias}.err.htm",
        delete  => 1,
    } );
    logg( "$reg->{code} $reg->{alias} - compressing MP" );
    rmove_glob("$basedir/$dirname/$reg->{mapid}.*", "$regdir_full");
    rcopy_glob("$regdir_full/$reg->{mapid}.mp","$basedir/$dirname");
    unlink "$basedir/_rel/$prefix.$reg->{alias}.mp.7z";
    `7za a -y $basedir/_rel/$prefix.$reg->{alias}.mp.7z $regdir_full`;
    rmtree("$regdir_full");

    $q_upl->enqueue( { 
        code    => $reg->{code},
        alias   => $reg->{alias},
        role    => 'MP',
        file    => "$basedir/_rel/$prefix.$reg->{alias}.mp.7z",
    } );

    return; 
} 


##  Thread routines

sub _source_download_thread {
    while ( my ($reg) = $q_src->dequeue() ) {
        last if !defined $reg;

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
                `wget $reg->{srcurl} -O $reg->{source} -o $filebase.wget.log 2> $devnull`;
            }
        }

        $q_bnd->enqueue( $reg );
    }

    logg( "All sources have been downloaded!" ) if !$skip_dl_src;
    $q_bnd->enqueue( undef );
    return;
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
                `$basedir/getbound.pl -o $reg->{poly} $onering $reg->{bound}  2>  $filebase.getbound.log`;
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
        if ( -f "$filebase.mp" ) {
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


sub _upload_thread {
    return if !$settings->{serv};

    while ( my ($file) = $q_upl->dequeue() ) {
        last if !defined $file;

        logg( "$file->{code} $file->{alias} - uploading $file->{role}" );
        my $auth = $settings->{auth} ? "-u $settings->{auth}" : q{};
        `curl --retry 100 $auth -T $file->{file} $settings->{serv} 2> $devnull`;
        unlink $file->{file}  if $file->{delete};
    }

    logg( "All files uploaded!" );
    return;
}


