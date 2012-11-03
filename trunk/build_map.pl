#! /usr/bin/perl

# FreeBSD version
# last edit 2012/11/03 (clean comments)

use strict;

use threads;
use threads::shared;
use Thread::Queue::Any;

use POSIX;
use Encode;
use YAML;
use File::Copy;
use File::Path;
use File::Copy::Recursive qw(rcopy_glob rmove_glob);



use Data::Dump 'dd';

use IO::Handle;

STDERR->autoflush(1);
STDOUT->autoflush(1);


my $basedir :shared = getcwd();

my $config_file_ftp = 'ftp.yml';
my ( $config_ref_ftp ) = YAML::LoadFile( $config_file_ftp );
my $auth :shared = exists($config_ref_ftp->{auth})     ?  $config_ref_ftp->{auth}        :  'anonymous:anonymous';
my $serv :shared = exists($config_ref_ftp->{serv})     ?  $config_ref_ftp->{serv}        :  '';

my $config_file = $ARGV[0]  //  'test.yml';
my $housesearch = $ARGV[1];

my ( $config_ref, $regions_ref ) = YAML::LoadFile( $config_file );

my @regions = @{ $regions_ref };
my @reglist :shared;

my $prefix  :shared = exists($config_ref->{prefix})     ?  $config_ref->{prefix}        :  'test';
my $cfgfile :shared = exists($config_ref->{config})     ?  $config_ref->{config}        :  'garmin.yml';
my $cfgfile_brokenmpoly :shared = exists($config_ref->{config_brokenmpoly})     ?  $config_ref->{config_brokenmpoly}        :  'garmin.yml';
my $fidbase :shared = exists($config_ref->{fid})        ?  $config_ref->{fid}           :  100;;
my $countrycode = exists($config_ref->{countrycode})    ?  $config_ref->{countrycode}   :  'test';
my $countryname = exists($config_ref->{countryname})    ?  $config_ref->{countryname}   :  'test';
my $filename    = exists($config_ref->{filename})       ?  $config_ref->{filename}      :  'test';
my $common_keys :shared = $config_ref->{keys} // q{};
my $name_postfix :shared = exists($config_ref->{name_postfix}) ? "$config_ref->{filename} " : q{};

my $today :shared = strftime( "%Y-%m-%d", localtime );


my $dirname :shared = "$prefix.gryphon.temp";
mkdir $dirname  unless -d $dirname;


my $q_src :shared = Thread::Queue::Any->new();
my $q_bnd :shared = Thread::Queue::Any->new();
my $q_bld :shared = Thread::Queue::Any->new();
my $q_upl :shared = Thread::Queue::Any->new();


logg( "Let's go!" );

`svn up open-cfg`;
my $svn_info=`svn info open-cfg`;
logg("svn info\n$svn_info");
rcopy_glob("open-cfg/osm.typ","osm.typ");
logg( "Configuration files updated" );



# Source downloading thread
my $t_src = threads->create( sub {
    while ( my ($reg) = $q_src->dequeue() ) {
        if ( defined $reg ) {
            logg( "$reg->{code} $reg->{alias} - downloading source" );
            unless ( -f "$dirname/$reg->{mapid}.img"  &&  -f "$dirname/$reg->{mapid}.img.idx"  ) {
        	$reg->{srcalias} = $reg->{alias}
        		unless (exists $reg->{srcalias});
	        $reg->{srcurl} = "http://data.gis-lab.info/osm_dump/dump/latest/$reg->{srcalias}.osm.pbf"
        		unless (exists $reg->{srcurl});
                $reg->{source} = "$basedir/_src/$prefix.$reg->{alias}.osm.pbf";
                `wget $reg->{srcurl} -O $reg->{source} -o $basedir/$dirname/$reg->{mapid}.wget.log 2>/dev/null`;
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
            unless ( -f "$dirname/$reg->{mapid}.img"  &&  -f "$dirname/$reg->{mapid}.img.idx"  ) {
                $reg->{bound} = $reg->{alias} unless exists $reg->{bound};
                my $onering = exists($reg->{onering})   ?  '--onering'    :  q{};
                $reg->{poly} = "$basedir/_bounds/$reg->{bound}.poly";
                `$basedir/getbound.pl -o $reg->{poly} $onering $reg->{bound}  2>  $basedir/$dirname/$reg->{mapid}.getbound.log`;
    		if ( $? != 0 ) {
	            logg( "Error! Can't get boundary $reg->{code} $reg->{alias}" );
    		}
            }
        };
        $q_bld->enqueue( $reg );
        unless ( defined $reg ) {
            logg( "All boundaries downloaded!" );
            return;
        }
    }
} );
logg( "Boundary downloading thread created" );




# Uploading thread
my $t_upl = threads->create( sub {
    while ( my ($file) = $q_upl->dequeue() ) {
        if ( defined $file ) {
            logg( "$file->{code} $file->{alias} - uploading $file->{role}" );
            `curl --retry 100 -u $auth -T $file->{file} $serv 2> nul`;
            unlink $file->{file} if exists $file->{delete};
        }
        else {
            logg( "All files uploaded!" );
            return;
        }
    }
} );
logg( "Uploading thread created" );




# Main building thread (cwd!)
my $t_bld = threads->create( sub {
    while ( my ($reg) = $q_bld->dequeue() ) {
        if ( defined $reg ) {
            if ( -f "$dirname/$reg->{mapid}.img"  &&  -f "$dirname/$reg->{mapid}.img.idx"  ) {
                logg( "$reg->{code} $reg->{alias} - already built" );
                for my $file ( glob "$dirname/$reg->{mapid}*.log" ) {
                    unlink $file;
                }

                push @reglist, $reg->{mapid};
                push @reglist, $reg->{mapid} + 10000000         if $housesearch;

                next;
            }
    

            logg( "$reg->{code} $reg->{alias} - converting to MP" );
            $reg->{keys} = q{} unless exists $reg->{keys};
            my $cmd =  qq{ 
                $basedir/osm2mp.pl -
                --config $cfgfile
                --mapid $reg->{mapid}
                --mapname "$reg->{name}"
                --bpoly $reg->{poly}
                --defaultcountry $countrycode
                --defaultregion "$reg->{name}"
                --countrylist "iso-3166-1-a2-ru.txt"
                --disableuturns
                --nodetectdupes
                --nointerchange3d
                --shorelines
                --hugesea 100000
                $common_keys
                $reg->{keys}
            };

            $cmd =~ s/\s+/ /g;
            `osmconvert "$reg->{source}" --out-osm | $cmd >"$dirname/$reg->{mapid}.mp" 2>"$dirname/$reg->{mapid}.osm2mp.log"`;
            if (exists $reg->{fixmultipoly} && $reg->{fixmultipoly}=="yes"){
                logg( "$reg->{code} $reg->{alias} - converting broken multipolygons to MP" );
                my $cmd_brokenmpoly = qq{ 
                    $basedir/osm2mp.pl -
                    --config $cfgfile_brokenmpoly
                    --mapid $reg->{mapid}
                    --mapname "$reg->{name}"
                    --bpoly $reg->{poly}
                    --defaultcountry $countrycode
                    --defaultregion "$reg->{name}"
                    --countrylist "iso-3166-1-a2-ru.txt"
                    --disableuturns
                    --nodetectdupes
                    --nointerchange3d
                    --shorelines
                    --hugesea 100000
                    $common_keys
                    $reg->{keys}
                };
                $cmd_brokenmpoly =~ s/\s+/ /g;
                `osmconvert "$reg->{source}" --out-osm | $basedir/getbrokenrelations.py 2>"$dirname/$reg->{mapid}.getbrokenrelations.log" | $cmd_brokenmpoly >>"$dirname/$reg->{mapid}.mp" 2>"$dirname/$reg->{mapid}.osm2mp.broken.log"`;
            }
            logg( "$reg->{code} $reg->{alias} - MP postprocess" );
            `$basedir/mp-postprocess.pl "$dirname/$reg->{mapid}.mp"`;

            `grep ERROR: $dirname/$reg->{mapid}.mp > $dirname/$reg->{mapid}.errors.log`;
            `$basedir/log2html.pl $dirname/$reg->{mapid}.errors.log > $basedir/_rel/$prefix.$reg->{alias}.err.htm`;
            $q_upl->enqueue( { 
                code    => $reg->{code},
                alias   => $reg->{alias},
                role    => 'error log',
                file    => "$basedir/_rel/$prefix.$reg->{alias}.err.htm",
                delete  => 1,
            } );

            logg( "$reg->{code} $reg->{alias} - compressing MP" );
            my $regdir = "$reg->{alias}_$today";
            mkdir $regdir;
            rmove_glob("$dirname/$reg->{mapid}.*", "$regdir");
            rcopy_glob("$regdir/$reg->{mapid}.mp","$dirname");
            unlink "$basedir/_rel/$prefix.$reg->{alias}.mp.7z";
            `7za a -y $basedir/_rel/$prefix.$reg->{alias}.mp.7z $regdir`;
            rmtree("$regdir");

            $q_upl->enqueue( { 
                code    => $reg->{code},
                alias   => $reg->{alias},
                role    => 'MP',
                file    => "$basedir/_rel/$prefix.$reg->{alias}.mp.7z",
            } );


            logg( "$reg->{code} $reg->{alias} - compiling IMG" );
            chdir $dirname;

            cgpsm_run("ac $reg->{mapid}.mp -e -l > $reg->{mapid}.cgpsmapper.log 2>>wine.log","$reg->{mapid}.img");

            
            if ( $housesearch ) {
                `$basedir/mp-housesearch.pl "$reg->{mapid}.mp" > "$reg->{mapid}-s.mp" 2>/dev/null`;
                cgpsm_run("ac $reg->{mapid}-s.mp -e -l >> $reg->{mapid}.cgpsmapper.log","$reg->{mapid}.img");
            }

            my $smp = $reg->{mapid} + 10000000;

            unlink "$reg->{mapid}.mp";
            unlink "$reg->{mapid}-s.mp"     if $housesearch;


            if ( -f "$reg->{mapid}.img" ) {
                logg( "$reg->{code} $reg->{alias} - indexing mapset" );
                push @reglist, $reg->{mapid};
                push @reglist, $smp         if $housesearch;

                open PV, '<', "$basedir/osm_pv.txt";
                my $pv = join '', <PV>;
                close PV;

                my $fid = $fidbase + $reg->{code};
                $pv =~ s/FID=888/FID=$fid/;
                $pv =~ s/MapsourceName=OpenStreetMap/MapsourceName=OSM $reg->{name} $name_postfix$today/;
                $pv =~ s/MapSetName=OpenStreetMap/MapSetName=OSM $reg->{name}/;
                $pv =~ s/CDSetName=OpenStreetMap/CDSetName=OSM $reg->{name}/;
                $pv =~ s/img=88888888.img/img=$reg->{mapid}.img\nimg=$smp.img/      if $housesearch;
                $pv =~ s/88888888/$reg->{mapid}/;

    
                open PV, '>:encoding(cp1251)', "pv.txt";
                print PV $pv;
                close PV;

                `cpreview pv.txt -m > $reg->{mapid}.cpreview.log`;
                unlink 'OSM.reg';
                cgpsm_run("OSM.mp 2>>wine.log", "OSM.img");

                unlink 'OSM.mp';
                unlink 'OSM.img.idx';

                open PV, '<', "$basedir/install.bat.ex";
                $pv = join '', <PV>;
                close PV;

                $pv =~ s/888/$fid/g;
                my $hfid = sprintf "%04X", ($fid >> 8) + (($fid & 0xFF) << 8);
                $pv =~ s/7803/$hfid/g;
    
                open PV, '>:encoding(cp1251)', "install.bat";
                print PV $pv;
                close PV;


                rcopy_glob("../osm.typ","./osm${fid}.typ");
                `gmt -wy $fid ./osm${fid}.typ`;
                
                ren_lowercase("*.*");

                logg( "$reg->{code} $reg->{alias} - compressing mapset" );

                mkdir $regdir;
                rmove_glob("$reg->{mapid}.*", "$regdir");
                rcopy_glob("$regdir/$reg->{mapid}.img*",".");
                rcopy_glob("$smp.img*", "$regdir")        if $housesearch;
                rmove_glob("osm*","$regdir");
                rmove_glob("*.txt","$regdir");
                rmove_glob("install.bat","$regdir");
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
logg( "Converting thread created" );




# Start!
REGION:
for my $reg ( @regions ) {

    $reg->{mapid} = sprintf "%08d", $fidbase*1000 + $reg->{code};
    $q_src->enqueue( $reg );
}

$q_src->enqueue( undef );

$t_src->join();
$t_bnd->join();
$t_bld->join();
$q_upl->enqueue( undef );



logg( "Indexing whole mapset" );

chdir $dirname;
open PV, '<', "$basedir/osm_pv1.txt";
my $pv = join '', <PV>;
close PV;

$pv =~ s/FID=888/FID=$fidbase\n/;
$pv =~ s/MapsourceName=OpenStreetMap/MapsourceName=OSM $countryname $name_postfix$today/;
$pv =~ s/MapSetName=OpenStreetMap/MapSetName=OSM $countryname/;
$pv =~ s/CDSetName=OpenStreetMap/CDSetName=OSM $countryname/;
$pv .= join '', map { "img=$_.img\n" } @reglist;
$pv .= "[End-Files]\n";

open PV, '>:encoding(cp1251)', "pv.txt";
print PV $pv;
close PV;


`cpreview pv.txt -m > cpreview.log`;
unlink "OSM.reg";
for my $mp (@reglist) {
#    unlink "$mp.img.idx";
}

cgpsm_run("OSM.mp 2>>wine.log", "OSM.img");

unlink 'OSM.mp';
unlink 'OSM.img.idx';

open PV, '<', "$basedir/install.bat.ex";
$pv = join '', <PV>;
close PV;

$pv =~ s/888/$fidbase/g;
my $hfid = sprintf "%04X", ($fidbase >> 8) + (($fidbase & 0xFF) << 8);
$pv =~ s/7803/$hfid/g;

open PV, '>:encoding(cp1251)', "install.bat";
print PV $pv;
close PV;


rcopy_glob("../osm.typ","./osm${fidbase}.typ");
`gmt -wy $fidbase ./osm${fidbase}.typ`;

ren_lowercase("*.*");

logg( "Compressing mapset" );

my $mapdir = "${filename}_$today";
mkdir $mapdir;
rmove_glob("*","$mapdir");
unlink "$basedir/_rel/$prefix.$filename.7z";
`7za a -y $basedir/_rel/$prefix.$filename.7z $mapdir`;
rmtree("$mapdir");

chdir $basedir;


logg( "Uploading mapset" );

`curl --retry 100 -u $auth -T $basedir/_rel/$prefix.$filename.7z $serv`;
rmtree("$dirname");


$t_upl->join();
logg( "That's all, folks!" );



sub logg {
    printf STDERR "%s:  %s\n", strftime("%Y-%m-%d %H:%M:%S", localtime), @_;
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
        while ($ret_code != 0 && $num<=5){
    	    `wine cgpsmapper.exe $_[0]`;
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
