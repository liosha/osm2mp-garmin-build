package App::OsmGetbound::RelAlias;

# ABSTRACT: human-readable aliases for osm relation ids

# $Id: RelAlias.pm 34 2013-11-05 11:47:13Z xliosha@gmail.com $

use 5.010;
use strict;
use warnings;
use autodie;
use utf8;

use Carp;
use Log::Any qw($log);

use FindBin '$Bin';
use YAML;


#our $DEFAULT_ALIAS_FILE = "$Bin/../etc/osm-getbound-aliases.yml";
our $DEFAULT_ALIAS_FILE = "$Bin/etc/osm-getbound-aliases.yml";


=head1 SYNOPSIS

    my $renamer = App::OsmGetbound::RelAlias->new($alias_file);
    my $rel_id = $renamer->get_id( $rel_alias );

=cut

=method new

Constructor.

    my $renamer = App::OsmGetbound::RelAlias->new($alias_file);

If $alias_file is undef, default ../etc/osm-getbound-aliases.yml will be used.

=cut

sub new {
    my ($class, $filename) = @_;
    my $self = bless {}, $class;

    $self->_init($filename)  if $filename;

    return $self;
}


=method get_id

    my $rel_id = $renamer->get_id( $rel_alias );

Returns id for $rel_alias, or undef if it is unknown;

=cut

sub get_id {
    my ($self, $alias) = @_;

    # digital aliases are id itself
    return $alias  if $alias =~ / ^ -? \d+ $ /xms;

    # lazy initialization
    $self->_init($DEFAULT_ALIAS_FILE)  if !$self->{table};

    my $id = $self->{table}->{$alias};
    $log->warn("Unknown alias $alias")  if !$id;
    return $id;
}

=method append 

    $renamer->append( $alias_file );

Loads one more alias file to the table

=cut

sub append {
    my ($self, $filename) = @_;

    my ($rename) = eval{ YAML::LoadFile $filename };
    croak "Unable to load aliases from $filename: $@"  if !$rename;

    while( ( my $k, my $v ) = each (%$rename) ) {
        $self->{table}->{$k} = $v;
    }
    return $self;
}


=method _init (internal)
=cut

sub _init {
    my ($self, $filename) = @_;

    my ($rename) = eval{ YAML::LoadFile $filename };
    croak "Unable to load aliases from $filename: $@"  if !$rename;

    $self->{table} = $rename;
    return $self;
}


1;

