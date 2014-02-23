package App::OsmGetbound::WriterShp;

# ABSTRACT:  writing polygons in Garmin MPC-compatible Shapefile format

# $Id: WriterShp.pm 33 2013-10-31 05:21:10Z xliosha@gmail.com $

use 5.010;
use strict;
use warnings;
use autodie;
use utf8;

use Carp;
use Log::Any qw($log);

use Geo::Shapefile::Writer;


=head1 SYNOPSIS

    App::OsmGetbound::WriterShp->new()->save( $filename, $name, \@contours );

=cut

=method new

Constructor.

    my $writer = App::OsmGetbound::WriterShp->new();

=cut

sub new { return bless {}, shift() }


=method save

    $writer->save( $filename, $name, \@contours );

Save data in Shapefile format.

=cut

sub save {
    my ($self, $outfile, $name, $contours) = @_;

    $outfile ||= 'out';

    my $shp = Geo::Shapefile::Writer->new( $outfile, 'POLYGON', qw/ NAME GRMN_TYPE / );

    # !!! todo: rearrange contours
    my @shp_contours =
        map {[ reverse @{$_->[0]} ]}
#        grep { !$_->[1] }  # skip inners?
        @$contours;

    $shp->add_shape( \@shp_contours, { GRMN_TYPE => 'DATA_BOUNDS' } );
    $shp->finalize();

    return;
}


1;

