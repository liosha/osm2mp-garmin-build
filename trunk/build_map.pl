#! /usr/bin/perl

# $Id$

use strict;
use uni::perl;

use Getopt::Long qw{ :config pass_through };

use threads;
use threads::shared;
use Thread::Queue::Any;
use Thread::Semaphore;

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
    'update-cfg!'   => \( my $update_cfg = 1 ),
);


if ( $config_file_ftp ) {
    my ($ftp) = YAML::LoadFile( $config_file_ftp );
    $settings->{$_} = $ftp->{$_} // q{}  for qw/ serv auth /;
}

$settings->{today} = strftime( "%Y-%m-%d", localtime );
$settings->{codepage} ||= 1251;
$settings->{encoding} = "cp$settings->{codepage}";

$settings = shared_clone( $settings );    


my $basedir = getcwd();
my $tt = Template->new( INCLUDE_PATH => "$basedir/templates" );



my $mp_threads_num :shared = 2; #number of the mp building threads

my $noupload :shared = 0; # do not upload to server flag

my $housesearch = $ARGV[1];


my @regions = @{ $regions };
my @reglist :shared;

my $prefix  :shared = exists($settings->{prefix})     ?  $settings->{prefix}        :  'test';
my $cfgfile :shared = exists($settings->{config})     ?  $settings->{config}        :  'garmin.yml';
my $cfgfile_brokenmpoly :shared = exists($settings->{config_brokenmpoly})     ?  $settings->{config_brokenmpoly}        :  'garmin.yml';
my $fidbase :shared = exists($settings->{fid})        ?  $settings->{fid}           :  100;;
my $countrycode = exists($settings->{countrycode})    ?  $settings->{countrycode}   :  'test';
my $countryname = exists($settings->{countryname})    ?  $settings->{countryname}   :  'test';
my $filename    = exists($settings->{filename})       ?  $settings->{filename}      :  'test';
my $common_keys :shared = $settings->{keys} // q{};
my $name_postfix :shared = exists($settings->{name_postfix}) ? "$settings->{filename} " : q{};

my $devnull :shared = $^O ~~ 'MSWin32' ? 'nul' : '/dev/null';


my $dirname :shared = "$prefix.gryphon.temp";
rmtree $dirname  if !$continue_mode;
mkdir $dirname  unless -d $dirname;
mkdir "_bounds"  unless -d "_bounds";
mkdir "_rel"  unless -d "_rel";
mkdir "_src"  unless -d "_src";


my $q_src :shared = Thread::Queue::Any->new();
my $q_bnd :shared = Thread::Queue::Any->new();
my $q_bld_mp :shared = Thread::Queue::Any->new();
my $q_bld_img :shared = Thread::Queue::Any->new();
my $q_upl :shared = Thread::Queue::Any->new();

my $sema_mp :shared = Thread::Semaphore->new($mp_threads_num);


logg( "Let's the fun begin! Building '$settings->{filename}'" );

if ( $update_cfg ) {
    logg( "Updating configuration" );
    `svn up open-cfg`;
    logg( "svn info:\n" . `svn info open-cfg` );
    rcopy_glob("open-cfg/osm.typ","osm.typ");
}


# Source downloading thread
my $t_src = threads->create( sub {
    while ( my ($reg) = $q_src->dequeue() ) {
        if ( defined $reg ) {
            logg( "$reg->{code} $reg->{alias} - downloading source" );
            unless ( -f "$basedir/$dirname/$reg->{mapid}.img"  &&  -f "$basedir/$dirname/$reg->{mapid}.img.idx"  ) {
            $reg->{srcalias} = $reg->{alias}
                unless (exists $reg->{srcalias});
            $reg->{srcurl} = "http://data.gis-lab.info/osm_dump/dump/latest/$reg->{srcalias}.osm.pbf"
                unless (exists $reg->{srcurl});
                $reg->{source} = "$basedir/_src/$prefix.$reg->{alias}.osm.pbf";
                `wget $reg->{srcurl} -O $reg->{source} -o $basedir/$dirname/$reg->{mapid}.wget.log 2> $devnull`;
            }
        };
        $q_bnd->enqueue( $reg );
        unless ( defined $reg ) {
            logg( "All sources downloaded!" );
            return;
        }
    }
} );
logg( "Source downloading thread created" );




# Boundary downloading thread
my $t_bnd = threads->create( sub {
    while ( my ($reg) = $q_bnd->dequeue() ) {
        if ( defined $reg ) {
            logg( "$reg->{code} $reg->{alias} - downloading boundary" );
            unless ( -f "$basedir/$dirname/$reg->{mapid}.img"  &&  -f "$basedir/$dirname/$reg->{mapid}.img.idx"  ) {
                $reg->{bound} = $reg->{alias} unless exists $reg->{bound};
                my $onering = exists($reg->{onering})   ?  '--onering'    :  q{};
                $reg->{poly} = "$basedir/_bounds/$reg->{bound}.poly";
                `$basedir/getbound.pl -o $reg->{poly} $onering $reg->{bound}  2>  $basedir/$dirname/$reg->{mapid}.getbound.log` unless $noupload;
            if ( $? != 0 ) {
                logg( "Error! Can't get boundary $reg->{code} $reg->{alias}" );
            }
            }
        };
        $q_bld_mp->enqueue( $reg );
        unless ( defined $reg ) {
            logg( "All boundaries downloaded!" );
            return;
        }
    }
} );
logg( "Boundary downloading thread created" );




# Uploading thread
my $t_upl = threads->create( \&_upload_thread ); 
logg( "Uploading thread created" );


sub build_mp {

    my $reg = @_[0];

    logg( "$reg->{code} $reg->{alias} - converting to MP" );
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
    
    
    $q_bld_img->enqueue( $reg );
    $sema_mp->up();

} 

# MP building thread
my $t_bld_mp = threads->create( sub {
    my @mp_threads=();
    while ( my ($reg) = $q_bld_mp->dequeue() ) {
        if ( defined $reg ) {
            if ( -f "$basedir/$dirname/$reg->{mapid}.mp" ) {
                logg( "$reg->{code} $reg->{alias} - MP already built" );
            $q_bld_img->enqueue( $reg );
                next;
            }
            $sema_mp->down();
        my $t_bld_mp_reg = threads->create( "build_mp", $reg );
        push(@mp_threads, $t_bld_mp_reg);
        };
        
        
    
        
        unless ( defined $reg ) {
            $sema_mp->down($mp_threads_num); #wait last threads to be finished
            $q_bld_img->enqueue( $reg );
            foreach my $thr (@mp_threads) {
            $thr->join();
            }
            logg( "All MP files has been built!" );
            return;
        }
    }
} );
logg( "MP building thread created" );

# IMG building thread
my $t_bld_img = threads->create( sub {
    while ( my ($reg) = $q_bld_img->dequeue() ) {
        if ( defined $reg ) {
            if ( -f "$dirname/$reg->{mapid}.img"  &&  -f "$dirname/$reg->{mapid}.img.idx"  ) {
                logg( "$reg->{code} $reg->{alias} - IMG already built" );

                push @reglist, $reg->{mapid};
                push @reglist, $reg->{mapid} + 10000000         if $housesearch;

                next;
            }

            logg( "$reg->{code} $reg->{alias} - compiling IMG" );
            my $regdir = "$reg->{alias}_$settings->{today}";
            mkdir "$dirname/$regdir";
            chdir "$dirname/$regdir";
            move("$basedir/$dirname/$reg->{mapid}.mp",".");

            cgpsm_run("ac $reg->{mapid}.mp -e -l > $reg->{mapid}.cgpsmapper.log 2> $devnull","$reg->{mapid}.img");
            if ( $housesearch ) {
                `$basedir/osm2mp/mp-housesearch.pl "$reg->{mapid}.mp" > "$reg->{mapid}-s.mp" 2> $devnull`;
                cgpsm_run("ac $reg->{mapid}-s.mp -e -l >> $reg->{mapid}.cgpsmapper.log","$reg->{mapid}.img");
            }
            my $smp = $reg->{mapid} + 10000000;

            unlink "$reg->{mapid}.mp";
            unlink "$reg->{mapid}-s.mp"     if $housesearch;

            if ( -f "$reg->{mapid}.img" ) {
                logg( "$reg->{code} $reg->{alias} - indexing mapset" );
                push @reglist, $reg->{mapid};
                push @reglist, $smp         if $housesearch;

                $reg->{fid} = $settings->{fid} + $reg->{code} // 0;

                my @files = ("$reg->{mapid}.img");
                push @files, "$smp.img"    if $housesearch;
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
                rcopy_glob("$regdir/$smp.img*", ".")        if $housesearch;
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
for my $reg ( @regions ) {

    $reg->{mapid} = sprintf "%08d", $fidbase*1000 + $reg->{code};
    $q_src->enqueue( $reg );
}

$q_src->enqueue( undef );

$t_src->join();
$t_bnd->join();
$t_bld_mp->join();
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


