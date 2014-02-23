package App::OsmGetbound::OsmData;

# ABSTRACT:  OSM xml data loader

# $Id: OsmData.pm 32 2013-10-30 13:46:30Z xliosha@gmail.com $

use 5.010;
use strict;
use warnings;
use autodie;
use utf8;

use Geo::Openstreetmap::Parser;
use Log::Any qw($log);


=head1 SYNOPSIS

    my $osm = App::OsmGetbound::OsmData->new();
    $osm->load( read_file '1.osm' );
    $osm->load( read_file '2.osm' );

=cut

=method new

    my $osm = App::OsmGetbound::OsmData->new();

Constructor

=cut

sub new {
    my ($class, %opt) = @_;
    my $self = bless {}, $class;

    return $self;
}


=method load

    $osm->load( read_file '1.osm' );

Load portion of data from xml

=cut

sub load {
    my ($self, $xml) = @_;

    my $new_data = parse_osm_xml($xml);
    for my $part ( qw/ nodes chains relations / ) {
        next if !$new_data->{$part};
        $self->{$part} = {( %{$self->{$part} || {}}, %{$new_data->{$part}} )};
    }

    return;
}


=func parse_osm_xml

    my $osm_data = Geo::Openstreetmap::Parser->parse_osm_xml( read_file '1.xml' );

Extract useful data from xml

=cut

sub parse_osm_xml {
    my ($xml) = @_;

    my %osm;
    my $parser = Geo::Openstreetmap::Parser->new(
        node => sub {
            my $attr = shift()->{attr};
            $osm{nodes}->{ $attr->{id} } = [ $attr->{lon}, $attr->{lat} ];
            return;
        },
        way => sub {
            my $obj = shift();
            my $id = $obj->{attr}->{id};
            $osm{chains}->{$id} = $obj->{nd};
            return;
        },
        relation => sub {
            my $obj = shift();
            my $id = $obj->{attr}->{id};
            $osm{relations}->{$id} = $obj;
            return;
        },
    );

    open my $fh, '<', \$xml;
    $parser->parse($fh);
    close $fh;

    return \%osm;
}

1;

