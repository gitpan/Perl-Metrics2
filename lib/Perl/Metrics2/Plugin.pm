package Perl::Metrics2::Plugin;

=pod

=head1 NAME

Perl::Metrics2::Plugin - Base class for Perl::Metrics Plugins

=head1 SYNOPSIS

  # Implement a simple metrics package which counts up the
  # use of each type of magic variable.
  package Perl::Metrics2::Plugin::Magic;
  
  use base 'Perl::Metrics2::Plugin';
  
  # Creates the metric 'all_magic'.
  # The total number of magic variables. 
  sub metric_all_magic {
      my ($self, $document) = @_;
      return scalar grep { $_->isa('PPI::Token::Magic') }
                    $document->tokens;
  }
  
  # The number of $_ "scalar_it" magic vars
  sub metric_scalar_it {
      my ($self, $document) = @_;
      return scalar grep { $_->content eq '$_' }
                    grep { $_->isa('PPI::Token::Magic') }
                    $document->tokens;
  }
  
  # ... and so on, and so forth.
  
  1;

=head1 DESCRIPTION

The L<Perl::Metrics> system does not in and of itself generate any actual
metrics data, it merely acts as a processing and storage engine.

The generation of the actual metrics data is done via metrics packages,
which as implemented as C<Perl::Metrics2::Plugin> sub-classes.

=head2 Implementing Your Own Metrics Package

Implementing a metrics package is pretty easy.

First, create a Perl::Metrics2::Plugin::Something package, inheriting
from C<Perl::Metrics2::Plugin>.

The create a subroutine for each metric, named metric_$name.

For each subroutine, you will be passed the plugin object itself, and the
L<PPI::Document> object to generate the metric for.

Return the metric value from the subroutine. And add as many metric_
methods as you wish. Methods not matching the pattern /^metric_(.+)$/
will be ignored, and you may use them for whatever support methods you
wish.

=head1 METHODS

=cut

use strict;
use Carp             ();
use Class::Inspector ();
use Params::Util     qw{ _IDENTIFIER _INSTANCE };
use Perl::Metrics2   ();

use vars qw{$VERSION};
BEGIN {
	$VERSION = '0.04';
}





#####################################################################
# Constructor

=pod

=head2 new

The C<new> constructor is quite trivial at this point, and is provided
merely as a convenience. You don't really need to think about this.

=cut

sub new {
	my $class = ref $_[0] ? ref shift : shift;
	my $self  = bless {
		seen => {},
	}, $class;
	return $self;
}

=pod

=head2 class

A convenience method to get the class for the plugin object,
to avoid having to use ref directly (and making the intent of
any code a little clearer).

=cut

sub class { ref $_[0] || $_[0] }

=pod

=head2 destructive

The destructive method is used by the plugin to indicate that the PPI
document passed in will be altered during the metric generation.

The value is used by the metrics engine to optimise document cloning and
reduce the number of expensive cloning to a minimum.

This value defaults to true for safety reasons, and should be overridden
in your subclass if your metrics are not destructive.

=cut

sub destructive { 1 }





#####################################################################
# Perl::Metrics2::Plugin API

=pod

=head2 metrics

The C<metrics> method provides the list of metrics that are provided
by the metrics package. By default, this list is automatically
generated for you scanning for C<metric_$name> methods that reside
in the immediate package namespace.

Returns a reference to a C<HASH> where the keys are the metric names,
and the values are the "version" of the metric (for versioned metrics),
or C<undef> if the metric is not versioned.

=cut

sub metrics {
	my $self = shift;
	$self->{_metrics} or
	$self->{_metrics} = $self->_metrics;	
}

sub _metrics {
	my $self    = shift;
	my $class   = ref $self;
	my $funcs   = Class::Inspector->functions($class)
		or Carp::croak("Failed to get method list for '$class'");
	my %metrics = map  { $_ => undef     }
	              grep { _IDENTIFIER($_) }
	              grep { s/^metric_//s   }
	              @$funcs;
	return \%metrics;
}

sub _metric {
	my ($self, $document, $name) = @_;
	my $method = "metric_$name";
	$self->can($method) or Carp::croak("Bad metric name '$name'");
	return scalar($self->$method($document));
}

# Prepopulate the seen index
sub study {
	my $self    = shift;
	my $class   = $self->class;
	my $version = $class->VERSION;
	my $md5     = Perl::Metrics2->selectcol_arrayref(
		'select distinct(md5) from file_metric where package = ? and version = ?',
		{}, $class, $version,
	);
	$self->{seen} = { map { $_ => 1 } @$md5 };
	return 1;
}

sub process_document {
	my $self     = shift;
	my $class    = ref $self;
	my $document = _INSTANCE(shift, 'PPI::Document');
	unless ( $document ) {
		Carp::croak("Did not provide a PPI::Document object");
	}
	my $hintsafe = !! shift;

	# Shortcut if already processed
	my $md5 = $document->hex_id;
	if ( $self->{seen}->{$md5} ) {
		return 1;
	}

	# Generate the new metrics values
	my %metric = $self->process_metrics($document, @_);

	# Flush out the old records and write the new metrics
	unless ( $hintsafe ) {
		# This can be an expensive call.
		# The hintsafe optional param lets the parent
		# indicate that this check is not required.
		Perl::Metrics2::FileMetric->delete(
			'where md5 = ? and package = ?',
			$md5, $class,
		);
	}

	# Temporary accelerate version
	SCOPE: {
		my $dbh = Perl::Metrics2->dbh;
		my $sth = $dbh->prepare(
			'INSERT INTO file_metric ( md5, package, version, name, value ) VALUES ( ?, ?, ?, ?, ? )'
		);
		foreach my $name ( sort keys %metric ) {
			$sth->execute( $md5, $class, $class->VERSION, $name, $metric{$name} );
		}
		$sth->finish;
	}
	#foreach my $name ( sort keys %metric ) {
		#Perl::Metrics2::FileMetric->create(
			#md5     => $md5,
			#package => $class,
			#version => $class->VERSION,
			#name    => $name,
			#value   => $metric{$name},
		#);
	#}

	# Remember that we have processed this document
	$self->{seen}->{$md5} = 1;

	return 1;
}

sub process_metrics {
	my $self     = shift;
	my $document = shift;
	my %metric   = %{$self->metrics};
	foreach my $name ( sort keys %metric ) {
		$metric{$name} = $self->_metric($document, $name);
	}
	return %metric;
}

1;

=pod

=head1 SUPPORT

Bugs should be reported via the CPAN bug tracker at

L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=Perl-Metrics2>

For other issues, contact the author.

=head1 AUTHOR

Adam Kennedy E<lt>adamk@cpan.orgE<gt>

=head1 SEE ALSO

L<Perl::Metrics>, L<PPI>

=head1 COPYRIGHT

Copyright 2009 Adam Kennedy.

This program is free software; you can redistribute
it and/or modify it under the same terms as Perl itself.

The full text of the license can be found in the
LICENSE file included with this module.

=cut
