# ==========================================================================
#
# ZoneMinder Object Module, $Date$, $Revision$
# Copyright (C) 2001-2017  ZoneMinder LLC
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# as published by the Free Software Foundation; either version 2
# of the License, or (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
#
# ==========================================================================
#
# This module contains the common definitions and functions used by the rest
# of the ZoneMinder scripts
#
package ZoneMinder::Object;

use 5.006;
use strict;
use warnings;

require ZoneMinder::Base;

our @ISA = qw(ZoneMinder::Base);

# ==========================================================================
#
# General Utility Functions
#
# ==========================================================================

use ZoneMinder::Config qw(:all);
use ZoneMinder::Logger qw(:all);
use ZoneMinder::Database qw(:all);

use vars qw/ $AUTOLOAD $log $dbh/;

*log = \$ZoneMinder::Logger::logger;
*dbh = \$ZoneMinder::Database::dbh;

my $debug = 1;
use constant DEBUG_ALL=>0;

sub new {
  my ( $parent, $id, $data ) = @_;

  my $self = {};
  bless $self, $parent;
  no strict 'refs';
  my $primary_key = ${$parent.'::primary_key'};
  if ( ! $primary_key ) {
    Error( 'NO primary_key for type ' . $parent );
    return;
  } # end if
  if ( ( $$self{$primary_key} = $id ) or $data ) {
#$log->debug("loading $parent $id") if $debug or DEBUG_ALL;
    $self->load( $data );
  }
  return $self;
} # end sub new

sub load {
  my ( $self, $data ) = @_;
  my $type = ref $self;
  if ( ! $data ) {
    no strict 'refs';
    my $table = ${$type.'::table'};
    if ( ! $table ) {
      Error( 'NO table for type ' . $type );
      return;
    } # end if
    my $primary_key = ${$type.'::primary_key'};
    if ( ! $primary_key ) {
      Error( 'NO primary_key for type ' . $type );
      return;
    } # end if

    if ( ! $$self{$primary_key} ) { 
      my ( $caller, undef, $line ) = caller;
      Error( (ref $self) . "::load called without $primary_key from $caller:$line");
    } else {
#$log->debug("Object::load Loading from db $type");
      Debug("Loading $type from $table WHERE $primary_key = $$self{$primary_key}");
      $data = $ZoneMinder::Database::dbh->selectrow_hashref( "SELECT * FROM $table WHERE $primary_key=?", {}, $$self{$primary_key} );
      if ( ! $data ) {
        if ( $ZoneMinder::Database::dbh->errstr ) {
          Error( "Failure to load Object record for $$self{$primary_key}: Reason: " . $ZoneMinder::Database::dbh->errstr );
        } else {
          Debug("No Results Loading $type from $table WHERE $primary_key = $$self{$primary_key}");
        } # end if
      } # end if
    } # end if
  } # end if ! $data
  if ( $data and %$data ) {
    @$self{keys %$data} = values %$data;
  } # end if
} # end sub load

sub AUTOLOAD {
  my ( $self, $newvalue ) = @_;
  my $type = ref($_[0]);
  my $name = $AUTOLOAD;
  $name =~ s/.*://;
  if ( @_ > 1 ) {
    return $_[0]{$name} = $_[1];
  }
  return $_[0]{$name};
}

sub save {
	my ( $self, $data, $force_insert ) = @_;

	my $type = ref $self;
	if ( ! $type ) {
		my ( $caller, undef, $line ) = caller;
		$log->error("No type in Object::save. self:$self from  $caller:$line");
	}
	my $local_dbh = eval '$'.$type.'::dbh';
	$local_dbh = $ZoneMinder::Database::dbh if ! $local_dbh;
	$self->set( $data ? $data : {} );
	if ( $debug or DEBUG_ALL ) {
		if ( $data ) {
			foreach my $k ( keys %$data ) {
				$log->debug("Object::save after set $k => $$data{$k} $$self{$k}");
			}
		} else {
			$log->debug("No data after set");
		}
	}
#$debug = 0;

	my $table = eval '$'.$type.'::table';
	my $fields = eval '\%'.$type.'::fields';
	my $debug = eval '$'.$type.'::debug';
	#$debug = DEBUG_ALL if ! $debug;

	my %sql;
	foreach my $k ( keys %$fields ) {
		$sql{$$fields{$k}} = $$self{$k} if defined $$fields{$k};
	} # end foreach
	if ( ! $force_insert ) {
		$sql{$$fields{updated_on}} = 'NOW()' if exists $$fields{updated_on};
	} # end if
	my $serial = eval '$'.$type.'::serial';
	my @identified_by = eval '@'.$type.'::identified_by';

	my $ac = sql::start_transaction( $local_dbh );
	if ( ! $serial ) {
		my $insert = $force_insert;
		my %serial = eval '%'.$type.'::serial';
		if ( ! %serial ) {
$log->debug("No serial") if $debug;
			# No serial columns defined, which means that we will do saving by delete/insert instead of insert/update
			if ( @identified_by ) {
				my $where = join(' AND ', map { $$fields{$_}.'=?' } @identified_by );
				if ( $debug ) {
					$log->debug("DELETE FROM $table WHERE $where");
				} # end if
				
				if ( ! ( ( $_ = $local_dbh->prepare("DELETE FROM $table WHERE $where") ) and $_->execute( @$self{@identified_by} ) ) ) {
					$where =~ s/\?/\%s/g;
					$log->error("Error deleting: DELETE FROM $table WHERE " .  sprintf($where, map { defined $_ ? $_ : 'undef' } ( @$self{@identified_by}) ).'):' . $local_dbh->errstr);
					$local_dbh->rollback();
					sql::end_transaction( $local_dbh, $ac );
					return $local_dbh->errstr;
				} elsif ( $debug ) {
					$log->debug("SQL succesful DELETE FROM $table WHERE $where");
				} # end if
			} # end if
			$insert = 1;
		} else {
			foreach my $id ( @identified_by ) {
				if ( ! $serial{$id} ) {
          my ( $caller, undef, $line ) = caller;
					$log->error("$id nor in serial for $type from $caller:$line") if $debug;
					next;
				}
				if ( ! $$self{$id} ) {
					($$self{$id}) = ($sql{$$fields{$id}}) = $local_dbh->selectrow_array( q{SELECT nextval('} . $serial{$id} . q{')} );
					$log->debug("SQL statement execution SELECT nextval('$serial{$id}') returned $$self{$id}") if $debug or DEBUG_ALL;
					$insert = 1;
				} # end if
			} # end foreach
		} # end if ! %serial

		if ( $insert ) {
			my @keys = keys %sql;
			my $command = "INSERT INTO $table (" . join(',', @keys ) . ') VALUES (' . join(',', map { '?' } @sql{@keys} ) . ')';
			if ( ! ( ( $_ = $local_dbh->prepare($command) ) and $_->execute( @sql{@keys} ) ) ) {
				my $error = $local_dbh->errstr;
				$command =~ s/\?/\%s/g;
				$log->error('SQL statement execution failed: ('.sprintf($command, , map { defined $_ ? $_ : 'undef' } ( @sql{@keys}) ).'):' . $local_dbh->errstr);
				$local_dbh->rollback();
				sql::end_transaction( $local_dbh, $ac );
				return $error;
			} # end if
			if ( $debug or DEBUG_ALL ) {
				$command =~ s/\?/\%s/g;
				$log->debug('SQL statement execution: ('.sprintf($command, , map { defined $_ ? $_ : 'undef' } ( @sql{@keys} ) ).'):' );
			} # end if
		} else {
			my @keys = keys %sql;
			my $command = "UPDATE $table SET " . join(',', map { $_ . ' = ?' } @keys ) . ' WHERE ' . join(' AND ', map { $_ . ' = ?' } @$fields{@identified_by} );
			if ( ! ( $_ = $local_dbh->prepare($command) and $_->execute( @sql{@keys,@$fields{@identified_by}} ) ) ) {
				my $error = $local_dbh->errstr;
				$command =~ s/\?/\%s/g;
				$log->error('SQL failed: ('.sprintf($command, , map { defined $_ ? $_ : 'undef' } ( @sql{@keys, @$fields{@identified_by}}) ).'):' . $local_dbh->errstr);
				$local_dbh->rollback();
				sql::end_transaction( $local_dbh, $ac );
				return $error;
			} # end if
			if ( $debug or DEBUG_ALL ) {
				$command =~ s/\?/\%s/g;
				$log->debug('SQL DEBUG: ('.sprintf($command, map { defined $_ ? $_ : 'undef' } ( @sql{@keys,@$fields{@identified_by}} ) ).'):' );
			} # end if
		} # end if
	} else { # not identified_by
		@identified_by = ('id') if ! @identified_by;
		my $need_serial = ! ( @identified_by == map { $$self{$_} ? $_ : () } @identified_by );

		if ( $force_insert or $need_serial ) {
			
			if ( $need_serial ) {
				if ( $serial ) {
					@$self{@identified_by} = @sql{@$fields{@identified_by}} = $local_dbh->selectrow_array( q{SELECT nextval('} . $serial . q{')} );
					if ( $local_dbh->errstr() )  {
						$log->error("Error getting next id. " . $local_dbh->errstr() );
						$log->error("SQL statement execution SELECT nextval('$serial') returned ".join(',',@$self{@identified_by}));
					} elsif ( $debug or DEBUG_ALL ) {
						$log->debug("SQL statement execution SELECT nextval('$serial') returned ".join(',',@$self{@identified_by}));
					} # end if
				} # end if
			} # end if
			my @keys = keys %sql;
			my $command = "INSERT INTO $table (" . join(',', @keys ) . ') VALUES (' . join(',', map { '?' } @sql{@keys} ) . ')';
			if ( ! ( $_ = $local_dbh->prepare($command) and $_->execute( @sql{@keys} ) ) ) {
				$command =~ s/\?/\%s/g;
				my $error = $local_dbh->errstr;
				$log->error('SQL failed: ('.sprintf($command, map { defined $_ ? $_ : 'undef' } ( @sql{@keys}) ).'):' . $error);
				$local_dbh->rollback();
				sql::end_transaction( $local_dbh, $ac );
				return $error;
			} # end if
			if ( $debug or DEBUG_ALL ) {
				$command =~ s/\?/\%s/g;
				$log->debug('SQL DEBUG: ('.sprintf($command, map { defined $_ ? $_ : 'undef' } ( @sql{@keys} ) ).'):' );
			} # end if
		} else {
			delete $sql{created_on};
			my @keys = keys %sql;
			@keys = sets::exclude( [ @$fields{@identified_by} ], \@keys );
			my $command = "UPDATE $table SET " . join(',', map { $_ . ' = ?' } @keys ) . ' WHERE ' . join(' AND ', map { $$fields{$_} .'= ?' } @identified_by );
			if ( ! ( $_ = $local_dbh->prepare($command) and $_->execute( @sql{@keys}, @sql{@$fields{@identified_by}} ) ) ) {
				my $error = $local_dbh->errstr;
				$command =~ s/\?/\%s/g;
				$log->error('SQL failed: ('.sprintf($command, map { defined $_ ? $_ : 'undef' } ( @sql{@keys}, @sql{@$fields{@identified_by}} ) ).'):' . $error) if $log;
				$local_dbh->rollback();
				sql::end_transaction( $local_dbh, $ac );
				return $error;
			} # end if
			if ( $debug or DEBUG_ALL ) {
				$command =~ s/\?/\%s/g;
				$log->debug('SQL DEBUG: ('.sprintf($command, map { defined $_ ? ( ref $_ eq 'ARRAY' ? join(',',@{$_}) : $_ ) : 'undef' } ( @sql{@keys}, @$self{@identified_by} ) ).'):' );
			} # end if
		} # end if
	} # end if
	sql::end_transaction( $local_dbh, $ac );
	$self->load();
	#if ( $$fields{id} ) {
		#if ( ! $ZoneMinder::Object::cache{$type}{$$self{id}} ) {
			#$ZoneMinder::Object::cache{$type}{$$self{id}} = $self;
		#} # end if
	#delete $ZoneMinder::Object::cache{$config{db_name}}{$type}{$$self{id}};
	#} # end if
#$log->debug("after delete");
	#eval 'if ( %'.$type.'::find_cache ) { %'.$type.'::find_cache = (); }';
#$log->debug("after clear cache");
	return '';
} # end sub save

sub set {
	my ( $self, $params ) = @_;
	my @set_fields = ();

	my $type = ref $self;
	my %fields = eval ('%'.$type.'::fields');
	if ( ! %fields ) {
		$log->warn('ZoneMinder::Object::set called on an object with no fields');
	} # end if
	my %defaults = eval('%'.$type.'::defaults');
	if ( ref $params ne 'HASH' ) {
		my ( $caller, undef, $line ) = caller;
		$openprint::log->error("$type -> set called with non-hash params from $caller $line");
	}

	foreach my $field ( keys %fields ) {
$log->debug("field: $field, param: ".$$params{$field}) if $debug;
		if ( exists $$params{$field} ) {
$openprint::log->debug("field: $field, $$self{$field} =? param: ".$$params{$field}) if $debug;
			if ( ( ! defined $$self{$field} ) or ($$self{$field} ne $params->{$field}) ) {
# Only make changes to fields that have changed
				if ( defined $fields{$field} ) {
					$$self{$field} = $$params{$field} if defined $fields{$field};
					push @set_fields, $fields{$field}, $$params{$field};	#mark for sql updating
				} # end if
$openprint::log->debug("Running $field with $$params{$field}") if $debug;
				if ( my $func = $self->can( $field ) ) {
					$func->( $self, $$params{$field} );
				} # end if
			} # end if
		} # end if

		if ( defined $fields{$field} ) {
			if ( $$self{$field} ) {
				$$self{$field} = transform( $type, $field, $$self{$field} );
			} # end if $$self{field}
		}
	} # end foreach field

	foreach my $field ( keys %defaults ) {

		if ( ( ! exists $$self{$field} ) or (!defined $$self{$field}) or ( $$self{$field} eq '' ) ) {
			$log->debug("Setting default ($field) ($$self{$field}) ($defaults{$field}) ") if $debug;
			if ( defined $defaults{$field} ) {
				$log->debug("Default $field is defined: $defaults{$field}") if $debug;
				if ( $defaults{$field} eq 'NOW()' ) {
					$$self{$field} = 'NOW()';
				} else {
					$$self{$field} = eval($defaults{$field});
					$log->error( "Eval error of object default $field default ($defaults{$field}) Reason: " . $@ ) if $@;
				} # end if
			} else {
				$$self{$field} = $defaults{$field};
			} # end if
#$$self{$field} = ( defined $defaults{$field} ) ? eval($defaults{$field}) : $defaults{$field};
			$log->debug("Setting default for ($field) using ($defaults{$field}) to ($$self{$field}) ") if $debug;
		} # end if
	} # end foreach default
	return @set_fields;
} # end sub set

sub transform {
	my $type = ref $_[0];
	$type = $_[0] if ! $type;
	my $fields = eval '\%'.$type.'::fields';
	my $value = $_[2];

	if ( defined $$fields{$_[1]} ) {
		my @transforms = eval('@{$'.$type.'::transforms{$_[1]}}');
		$openprint::log->debug("Transforms for $_[1] before $_[2]: @transforms") if $debug;
		if ( @transforms ) {
			foreach my $transform ( @transforms ) {
				if ( $transform =~ /^s\// or $transform =~ /^tr\// ) {
					eval '$value =~ ' . $transform;
				} elsif ( $transform =~ /^<(\d+)/ ) {
					if ( $value > $1 ) {
						$value = undef;
					} # end if
				} else {
	$openprint::log->debug("evalling $value ".$transform . " Now value is $value" );
					eval '$value '.$transform;
	$openprint::log->error("Eval error $@") if $@;
				}
	$openprint::log->debug("After $transform: $value") if $debug;
			} # end foreach
		} # end if 
	} else {
		$openprint::log->error("Object::transform ($_[1]) not in fields for $type");
	} # end if
	return $value;

} # end sub transform
1;
__END__

# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

ZoneMinder::Object

=head1 SYNOPSIS

  use parent ZoneMinder::Object;
  
  This package should likely not be used directly, as it is meant mainly to be a parent for all other ZoneMinder classes.

=head1 DESCRIPTION

  A base Object to act as parent for other ZoneMinder Objects.

=head2 EXPORT

None by default.

=head1 AUTHOR

Isaac Connor, E<lt>isaac@zoneminder.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2001-2017  ZoneMinder LLC

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.3 or,
at your option, any later version of Perl 5 you may have available.


=cut
