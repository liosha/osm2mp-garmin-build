package App::OsmGetbound::OsmApiClient;

# ABSTRACT: OSM data downloader

# $Id: OsmApiClient.pm 31 2013-10-30 12:22:55Z xliosha@gmail.com $

use 5.010;
use strict;
use warnings;
use utf8;


use Carp;
use Log::Any qw($log);
use LWP::UserAgent;

=head1 SYNOPSIS

    my $api = App::OsmGetbound::OsmApiClient->new( api => 'op_ru' );

=cut

=head1 PACKAGE VARIABLES
=head2 %API

    $App::OsmGetbound::OsmApiClient::API{op_de} = [ overpass => 'http://overpass-api.de/api' ];

List of known OSM API servers in format ( $api_id => [ $api_type => $api_main_url ] ).

Supported $api_type are: osm, overpass.

=cut

our %API = (
    osm     => [ osm => 'http://www.openstreetmap.org/api/0.6' ],
    op_ru   => [ overpass => 'http://overpass.osm.rambler.ru/cgi' ],
    op_de   => [ overpass => 'http://overpass-api.de/api' ],
);

our $HTTP_TIMEOUT = 300;


=method new

    my $api = App::OsmGetbound::OsmApiClient->new( %opt );
    my $node_xmls = $api->get_object( node => 123456 );
    my $way_xmls = $api->get_object( way => 12345, 'full' );

Constructor.

Supported options:

    * api - $api_id to use, default: osm
    * proxy
    * http_timeout

=cut

sub new {
    my ($class, %opt) = @_;

    my $self = bless { opt => \%opt }, $class;

    $self->{api} = $opt{api} || 'osm';
    croak "Unknown api: $self->{api}"  if !$API{$self->{api}};

    return $self;
}


=method get_object

    my $xmls = $api->get_object( $osm_type => $osm_id, $is_full );

Downloads xml data from OSM API.
Tries to get all data in one request, and if it fails (object is too large), tries to get by parts.

Returns XML or list of XMLs.

=cut

sub get_object {
    my ($self, $type, $id, $is_full) = @_;

    my $url = $self->_get_object_url( $type => $id, $is_full );
    my $xml = $self->_http_get( $url, retry => 1 );
    return $xml  if $xml;

    die "Failed to get $type ID=$id"  if !($type eq 'relation' && $is_full);

    # try to download big relation by parts
    $log->inform("Failed, trying by parts");

    my $rel_xml = $self->get_object($type => $id, 0);
    die "Failed to get $type ID=$id"  if !$rel_xml;

    my $osm = App::OsmGetbound::OsmData->parse_osm_xml($rel_xml);
    my $relation = $osm->{relations}->{$id};
    
    my @xmls = ($rel_xml);
    for my $member ( @{ $relation->{member} } ) {
        my $part_xml = $self->get_object(
            $member->{type} => $member->{ref},
            ($member->{type} eq 'relation' ? 0 : 'full')
        );
        push @xmls, $part_xml;
    }

    return \@xmls;
}


=method _init_ua (internal)
=cut

sub _init_ua {
    my ($self) = @_;
    return $self->{ua} if $self->{ua};

    my $ua = $self->{ua} = LWP::UserAgent->new();
    $ua->proxy( 'http', $self->{opt}->{proxy} )    if $self->{opt}->{proxy};
    $ua->default_header('Accept-Encoding' => 'gzip');
    $ua->timeout( $self->{opt}->{http_timeout} // $HTTP_TIMEOUT );

    return $ua;
}


=method _http_get (internal)
=cut

sub _http_get {
    my ($self, $url, %opt) = @_;
    my $ua = $self->_init_ua();
    
    $log->inform("GET $url");
    my $req = HTTP::Request->new( GET => $url );

    my $res;
    for my $attempt ( 0 .. $opt{retry} || 0 ) {
        # logg ". attempt $attempt";
        $res = $ua->request($req);
        last if $res->is_success();
    }

    if ( !$res->is_success() ) {
        $log->warn("Download failed: ". ${res}->status_line());
        return;
    }

    return $res->decoded_content();
}


=method _get_object_url (internal)
=cut

sub _get_object_url {
    my ($self, $obj, $id, $is_full) = @_;
    my ($api_type, $api_url) = @{$API{$self->{api}}};

    my $url;
    if ( $api_type ~~ 'osm' ) {
        $url = "$api_url/$obj/$id";
        $url .= '/full'  if $is_full && $obj ne 'node';
    }
    elsif ( $api_type ~~ 'overpass' ) {
        my $query = "data=$obj($id);";
        $query .= '(._;>);'  if $is_full;
        $url = "$api_url/interpreter?${query}out meta;";
    }
    else {
        croak "Unknown api type: $api_type";
    }

    return $url;
}

1;


