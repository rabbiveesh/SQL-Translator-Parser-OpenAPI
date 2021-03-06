package SQL::Translator::Parser::OpenAPI;
use strict;
use warnings;
use JSON::Validator::OpenAPI;

our $VERSION = "0.05";
use constant DEBUG => $ENV{SQLTP_OPENAPI_DEBUG};
use String::CamelCase qw(camelize decamelize);
use Lingua::EN::Inflect::Number qw(to_PL to_S);
use SQL::Translator::Schema::Constants;
use Hash::MoreUtils qw(slice_grep);
use Hash::Merge qw(merge);
use Yancy::Util qw(definitions_non_fundamental);

my %TYPE2SQL = (
  integer => 'int',
  int32 => 'int',
  int64 => 'bigint',
  float => 'float',
  number => 'double',
  double => 'double',
  string => 'varchar',
  byte => 'byte',
  binary => 'binary',
  boolean => 'bit',
  date => 'date',
  'date-time' => 'datetime',
  password => 'varchar',
);
my %SQL2TYPE = reverse %TYPE2SQL; # unreliable order but ok as still reversible

# from GraphQL::Debug
sub _debug {
  my $func = shift;
  require Data::Dumper;
  require Test::More;
  local ($Data::Dumper::Sortkeys, $Data::Dumper::Indent, $Data::Dumper::Terse);
  $Data::Dumper::Sortkeys = $Data::Dumper::Indent = $Data::Dumper::Terse = 1;
  Test::More::diag("$func: ", Data::Dumper::Dumper([ @_ ]));
}

sub _prop2sqltype {
  my ($prop) = @_;
  my $format_type = $prop->{format} || $prop->{type};
  my $lookup = $TYPE2SQL{$format_type || ''};
  DEBUG and _debug("_prop2sqltype($format_type)($lookup)", $prop);
  my %retval = (data_type => $lookup);
  if (@{$prop->{enum} || []}) {
    $retval{data_type} = 'enum';
    $retval{extra} = { list => [ @{$prop->{enum}} ] };
  }
  DEBUG and _debug("_prop2sqltype(end)", \%retval);
  \%retval;
}

sub _make_not_null {
  my ($table, $field_in) = @_;
  my @fields = ref($field_in) eq 'ARRAY' ? @$field_in : $field_in;
  for my $field (@fields) {
    $field->is_nullable(0);
  }
  $table->add_constraint(type => $_, fields => \@fields)
    for (NOT_NULL);
}

sub _make_pk {
  my ($table, $field_in) = @_;
  my @fields = ref($field_in) eq 'ARRAY' ? @$field_in : $field_in;
  $_->is_primary_key(1) for @fields;
  $fields[0]->is_auto_increment(1) if @fields == 1 and $fields[0]->data_type =~ /int/;
  $table->add_constraint(type => $_, fields => \@fields)
    for (PRIMARY_KEY);
  my $index = $table->add_index(
    name => join('_', 'pk', map $_->name, @fields),
    fields => \@fields,
  );
  _make_not_null($table, \@fields);
}

sub _def2tablename {
  my ($def, $args) = @_;
  return $def unless $args->{snake_case};
  to_PL decamelize $def;
}

sub _ref2def {
  my ($ref) = @_;
  $ref =~ s:^#/definitions/:: or return;
  $ref;
}

sub _make_fk {
  my ($table, $field, $foreign_tablename, $foreign_id) = @_;
  $table->add_constraint(
    type => FOREIGN_KEY, fields => $field,
    reference_table => $foreign_tablename,
    reference_fields => $foreign_id,
  );
}

sub _get_entity {
  my ($schema, $name, $view2real) = @_;
  $schema->get_table($name) || $schema->get_table($view2real->{$name});
}

sub _fk_hookup {
  my ($schema, $fromtable, $fromkey, $totable, $tokey, $required, $view2real) = @_;
  DEBUG and _debug("_fk_hookup $fromtable.$fromkey $totable.$tokey $required");
  my $from_obj = $schema->get_table($fromtable);
  my $to_obj = _get_entity($schema, $totable, $view2real);
  my $tokey_obj = $to_obj->get_field($tokey);
  my $field = $from_obj->get_field($fromkey) || $from_obj->add_field(
    name => $fromkey, data_type => $tokey_obj->data_type,
  );
  die $from_obj->error if !$field;
  _make_fk($from_obj, $field, $to_obj->name, $tokey);
  _make_not_null($from_obj, $field) if $required;
  $field;
}

sub _def2table {
  my ($name, $def, $schema, $m2m, $view2real, $def2relationalid, $args) = @_;
  my $props = $def->{properties};
  my $tname = _def2tablename($name, $args);
  DEBUG and _debug("_def2table($name)($tname)($m2m)", $props);
  if (my $view_of = $def->{'x-view-of'}) {
    my $target_table = _def2tablename($view_of, $args);
    $view2real->{$tname} = $target_table;
    return (undef, []);
  }
  my $table = $schema->add_table(
    name => $tname, comments => $def->{description},
  );
  my $relational_id_field = $def2relationalid->{$name};
  if (!$m2m and !$props->{$relational_id_field}) {
    # we need a relational id
    $props->{$relational_id_field} = { type => 'integer' };
  }
  my %prop2required = map { ($_ => 1) } @{ $def->{required} || [] };
  my (@fixups);
  for my $propname (sort keys %$props) {
    my $field;
    my $thisprop = $props->{$propname};
    DEBUG and _debug("_def2table($propname)");
    if (my $ref = $thisprop->{'$ref'}) {
      my $refname = _ref2def($ref);
      push @fixups, {
        from => $tname,
        fromkey => $propname . '_id',
        to => _def2tablename($refname, $args),
        tokey => $def2relationalid->{$refname},
        required => $prop2required{$propname},
        type => 'one',
      };
    } elsif (($thisprop->{type} // '') eq 'array') {
      if (my $ref = $thisprop->{items}{'$ref'}) {
        my $refname = _ref2def($ref);
        my $fromkey;
        if ($args->{snake_case}) {
          $fromkey = to_S($propname) . "_id";
        } else {
          $fromkey = $propname . "_id";
        }
        push @fixups, {
          from => _def2tablename($refname, $args),
          fromkey => $fromkey,
          to => $tname,
          tokey => $relational_id_field,
          required => 1,
          type => 'many',
        };
      }
      DEBUG and _debug("_def2table(array)($propname)", \@fixups);
    } else {
      my $sqltype = _prop2sqltype($thisprop);
      $field = $table->add_field(
        name => $propname, %$sqltype, comments => $thisprop->{description},
      );
      if ($propname eq ($relational_id_field // '')) {
        _make_pk($table, $field);
      } elsif ($propname eq ($def->{'x-id-field'} // '')) {
        $table->add_constraint(type => $_, fields => [ $field ])
          for (UNIQUE);
        my $index = $table->add_index(
          name => join('_', 'unique', map $_->name, $field),
          fields => [ $field ],
        );
      }
    }
    if ($field and $prop2required{$propname} and $propname ne $relational_id_field) {
      _make_not_null($table, $field);
    }
  }
  if ($m2m) {
    _make_pk($table, scalar $table->get_fields);
  }
  DEBUG and _debug("table", $table, \@fixups);
  ($table, \@fixups);
}

sub _merge_allOf {
  my ($defs) = @_;
  DEBUG and _debug('OpenAPI._merge_allOf', $defs);
  my %r2ds = slice_grep { $_{$_}{allOf} } $defs;
  my @defref_pairs = map {
    my $referrer = $_;
    map [ $_, $referrer ],
      grep $defs->{$_}{discriminator}, map _ref2def($_), grep defined, map $_->{'$ref'}, @{ $r2ds{$referrer}{allOf} }
  } keys %r2ds;
  DEBUG and _debug('OpenAPI._merge_allOf(defref_pairs)', \@defref_pairs);
  my %newdefs = %$defs;
  my %def2ignore;
  for (@defref_pairs) {
    my ($defname, $assimilee) = @$_;
    @def2ignore{@$_} = (1, 1);
    $newdefs{$defname} = merge $newdefs{$defname}, $_
      for grep !$_->{'$ref'}, @{ $defs->{$assimilee}{allOf} };
  }
  for my $defname (grep !$def2ignore{$_} && exists $newdefs{$_}{allOf}, keys %$defs) {
    $newdefs{$defname} = merge $newdefs{$defname}, (exists $_->{'$ref'}
      ? $defs->{ _ref2def($_->{'$ref'}) }
      : $_) for @{ $newdefs{$defname}{allOf} };
    delete $newdefs{$defname}{allOf}; # delete as will now be copy
  }
  DEBUG and _debug('OpenAPI._merge_allOf(end)', \%newdefs);
  \%newdefs;
}

sub _extract_objects {
  my ($defs, $args) = @_;
  DEBUG and _debug('OpenAPI._extract_objects', $defs);
  my %newdefs = %$defs;
  for my $defname (sort keys %$defs) {
    my $theseprops = $defs->{$defname}{properties} || {};
    for my $propname (keys %$theseprops) {
      my $thisprop = $theseprops->{$propname};
      next if $thisprop->{'$ref'}
        or $thisprop->{items} && $thisprop->{items}{'$ref'};
      my $ref;
      if (($thisprop->{type} // '') eq 'object') {
        $ref = $thisprop;
      } elsif (
        $thisprop->{items} && ($thisprop->{items}{type} // '') eq 'object'
      ) {
        $ref = $thisprop->{items};
      } else {
        next;
      }
      my $newtype;
      if ($args->{snake_case}) {
        $newtype = join '', map camelize($_), $defname, $propname;
      } else {
        $newtype = join '_', $defname, $propname;
      }
      $newdefs{$newtype} = { %$ref };
      %$ref = ('$ref' => "#/definitions/$newtype");
    }
  }
  DEBUG and _debug('OpenAPI._extract_objects(end)', [ sort keys %newdefs ], \%newdefs);
  \%newdefs;
}

sub _extract_array_simple {
  my ($defs, $args) = @_;
  DEBUG and _debug('OpenAPI._extract_array_simple', $defs);
  my %newdefs = %$defs;
  for my $defname (sort keys %$defs) {
    my $theseprops = $defs->{$defname}{properties} || {};
    for my $propname (keys %$theseprops) {
      my $thisprop = $theseprops->{$propname};
      next if $thisprop->{'$ref'};
      next unless
        $thisprop->{items} && ($thisprop->{items}{type} // '') ne 'object';
      my $ref = $thisprop->{items};
      my $newtype;
      if ($args->{snake_case}) {
        $newtype = join '', map camelize($_), $defname, $propname;
      } else {
        $newtype = join '_', $defname, $propname;
      }
      $newdefs{$newtype} = {
        type => 'object',
        properties => {
          value => { %$ref }
        },
        required => [ 'value' ],
      };
      %$ref = ('$ref' => "#/definitions/$newtype");
    }
  }
  DEBUG and _debug('OpenAPI._extract_array_simple(end)', [ sort keys %newdefs ], \%newdefs);
  \%newdefs;
}

sub _fixup_addProps {
  my ($defs) = @_;
  DEBUG and _debug('OpenAPI._fixup_addProps', $defs);
  my %def2aP = map {$_,1} grep $defs->{$_}{additionalProperties}, keys %$defs;
  DEBUG and _debug("OpenAPI._fixup_addProps(d2aP)", \%def2aP);
  for my $defname (sort keys %$defs) {
    my $theseprops = $defs->{$defname}{properties} || {};
    DEBUG and _debug("OpenAPI._fixup_addProps(arrayfix)($defname)", $theseprops);
    for my $propname (keys %$theseprops) {
      my $thisprop = $theseprops->{$propname};
      DEBUG and _debug("OpenAPI._fixup_addProps(p)($propname)", $thisprop);
      next unless $thisprop->{'$ref'}
        or $thisprop->{items} && $thisprop->{items}{'$ref'};
      DEBUG and _debug("OpenAPI._fixup_addProps(p)($propname)(y)");
      my $ref;
      if ($thisprop->{'$ref'}) {
        $ref = $thisprop;
      } elsif ($thisprop->{items} && $thisprop->{items}{'$ref'}) {
        $ref = $thisprop->{items};
      } else {
        next;
      }
      my $refname = $ref->{'$ref'};
      DEBUG and _debug("OpenAPI._fixup_addProps(p)($propname)(y2)($refname)", $ref);
      next if !$def2aP{_ref2def($refname)};
      %$ref = (type => 'array', items => { '$ref' => $refname });
      DEBUG and _debug("OpenAPI._fixup_addProps(p)($propname)(y3)", $ref);
    }
  }
  my %newdefs = %$defs;
  for my $defname (keys %def2aP) {
    my %kv = (type => 'object', properties => {
      key => { type => 'string' },
      value => { type => $defs->{$defname}{additionalProperties}{type} },
    });
    $newdefs{$defname} = \%kv;
  }
  DEBUG and _debug('OpenAPI._fixup_addProps(end)', \%newdefs);
  \%newdefs;
}

sub _absorb_nonobject {
  my ($defs) = @_;
  DEBUG and _debug('OpenAPI._absorb_nonobject', $defs);
  my %def2nonobj = map {$_,1} grep $defs->{$_}{type} ne 'object', keys %$defs;
  DEBUG and _debug("OpenAPI._absorb_nonobject(d2nonobj)", \%def2nonobj);
  for my $defname (sort keys %$defs) {
    my $theseprops = $defs->{$defname}{properties} || {};
    DEBUG and _debug("OpenAPI._absorb_nonobject(t)($defname)", $theseprops);
    for my $propname (keys %$theseprops) {
      my $thisprop = $theseprops->{$propname};
      DEBUG and _debug("OpenAPI._absorb_nonobject(p)($propname)", $thisprop);
      next unless $thisprop->{'$ref'}
        or $thisprop->{items} && $thisprop->{items}{'$ref'};
      DEBUG and _debug("OpenAPI._absorb_nonobject(p)($propname)(y)");
      my $ref;
      if ($thisprop->{'$ref'}) {
        $ref = $thisprop;
      } elsif ($thisprop->{items} && $thisprop->{items}{'$ref'}) {
        $ref = $thisprop->{items};
      } else {
        next;
      }
      my $refname = $ref->{'$ref'};
      DEBUG and _debug("OpenAPI._absorb_nonobject(p)($propname)(y2)($refname)", $ref);
      my $refdef = _ref2def($refname);
      next if !$def2nonobj{$refdef};
      %$ref = %{ $defs->{$refdef} };
      DEBUG and _debug("OpenAPI._absorb_nonobject(p)($propname)(y3)", $ref);
    }
  }
  my %newdefs = %$defs;
  delete @newdefs{ keys %def2nonobj };
  DEBUG and _debug('OpenAPI._absorb_nonobject(end)', \%newdefs);
  \%newdefs;
}

sub _tuple2name {
  my ($fixup, $args) = @_;
  my $from = $fixup->{from};
  my $fromkey = $fixup->{fromkey};
  $fromkey =~ s#_id$##;
  if ($args->{snake_case}) {
    camelize join '_', map to_S($_), $from, $fromkey;
  } else {
    join '_', $from, $fromkey;
  }
}

sub _make_many2many {
  my ($fixups, $schema, $def2relationalid, $args) = @_;
  DEBUG and _debug("_make_many2many", $fixups);
  my @manyfixups = grep $_->{type} eq 'many', @$fixups;
  my %from_tos;
  push @{ $from_tos{$_->{from}}{$_->{to}} }, $_ for @manyfixups;
  my %to_froms;
  push @{ $to_froms{$_->{to}}{$_->{from}} }, $_ for @manyfixups;
  my %m2m;
  my %ref2nonm2mfixup;
  $ref2nonm2mfixup{$_} = $_ for @$fixups;
  for my $from (keys %from_tos) {
    for my $to (keys %{ $from_tos{$from} }) {
      for my $fixup (@{ $from_tos{$from}{$to} }) {
        for my $other (@{ $to_froms{$from}{$to} }) {
          my ($f1, $f2) = sort { $a->{from} cmp $b->{from} } $fixup, $other;
          $m2m{_tuple2name($f1, $args)}{_tuple2name($f2, $args)} = [ $f1, $f2 ];
          delete $ref2nonm2mfixup{$_} for $f1, $f2;
        }
      }
    }
  }
  my @replacefixups;
  for my $n1 (sort keys %m2m) {
    for my $n2 (sort keys %{ $m2m{$n1} }) {
      my ($f1, $f2) = @{ $m2m{$n1}{$n2} };
      my ($t1_obj, $t2_obj) = map $schema->get_table($_->{to}), $f1, $f2;
      my $f1_fromkey = $f1->{fromkey};
      my $f2_fromkey = $f2->{fromkey};
      if ($f1_fromkey eq $f2_fromkey and $f1->{from} eq $f2->{from}) {
        $f1_fromkey =~ s#_id$#_to_id#;
        $f2_fromkey =~ s#_id$#_from_id#;
      }
      my $new_table = $n1.$n2;
      if ($args->{snake_case}) {
        $new_table = $n1.$n2;
      } else {
        $new_table = join '_', $n1, $n2;
      }
      my ($table) = _def2table(
        $new_table,
        {
          type => 'object',
          properties => {
            $f1_fromkey => {
              type => $SQL2TYPE{$t1_obj->get_field($f1->{tokey})->data_type}
            },
            $f2_fromkey => {
              type => $SQL2TYPE{$t2_obj->get_field($f2->{tokey})->data_type}
            },
          },
        },
        $schema,
        1,
        undef,
        $def2relationalid,
        $args,
      );
      push @replacefixups, {
        to => $f1->{from},
        tokey => 'id',
        from => $table->name,
        fromkey => $f1_fromkey,
        required => 1,
      }, {
        to => $f2->{from},
        tokey => 'id',
        from => $table->name,
        fromkey => $f2_fromkey,
        required => 1,
      };
    }
  }
  my @newfixups = (
    (sort {
        $a->{from} cmp $b->{from} || $a->{fromkey} cmp $b->{fromkey}
    } values %ref2nonm2mfixup),
    @replacefixups,
  );
  DEBUG and _debug("fixups still to do", \@newfixups);
  \@newfixups;
}

sub _remove_fields {
  my ($defs, $name) = @_;
  DEBUG and _debug("OpenAPI._remove_fields($name)", $defs);
  for my $defname (sort keys %$defs) {
    my $theseprops = $defs->{$defname}{properties} || {};
    DEBUG and _debug("OpenAPI._remove_fields(t)($defname)", $theseprops);
    for my $propname (keys %$theseprops) {
      my $thisprop = $theseprops->{$propname};
      DEBUG and _debug("OpenAPI._remove_fields(p)($propname)", $thisprop);
      delete $theseprops->{$propname} if $thisprop->{$name};
    }
  }
}

sub _decide_id_fields {
  my ($defs) = @_;
  DEBUG and _debug('OpenAPI._decide_id_fields', $defs);
  my %def2relationalid;
  for my $defname (sort keys %$defs) {
    my $thisdef = $defs->{$defname} || {};
    my $theseprops = $thisdef->{properties} || {};
    DEBUG and _debug("OpenAPI._decide_id_fields($defname)", $thisdef);
    if (
      ($theseprops->{id} and $theseprops->{id}{type} =~ /int/) or
      !$theseprops->{id}
    ) {
      $def2relationalid{$defname} = 'id';
    } elsif (
      ($thisdef->{'x-id-field'} and $theseprops->{$thisdef->{'x-id-field'}}{type} =~ /int/)
    ) {
      $def2relationalid{$defname} = $thisdef->{'x-id-field'};
    } else {
      $def2relationalid{$defname} = _find_unique_name($theseprops);
    }
  }
  DEBUG and _debug('OpenAPI._decide_id_fields(end)', \%def2relationalid);
  \%def2relationalid;
}

sub _find_unique_name {
  my ($props) = @_;
  DEBUG and _debug('OpenAPI._find_unique_name', $props);
  my $id_field = '_relational_id00';
  $id_field++ while $props->{$id_field};
  DEBUG and _debug('OpenAPI._find_unique_name(end)', $id_field);
  $id_field;
}

sub parse {
  my ($tr, $data) = @_;
  my $args = $tr->parser_args;
  my $openapi_schema = JSON::Validator::OpenAPI->new->schema($data)->schema;
  my %defs = %{ $openapi_schema->get("/definitions") };
  DEBUG and _debug('OpenAPI.definitions', \%defs);
  my $schema = $tr->schema;
  DEBUG and $schema->translator(undef); # reduce debug output
  _remove_fields(\%defs, 'x-artifact');
  _remove_fields(\%defs, 'x-input-only');
  %defs = %{ _merge_allOf(\%defs) };
  my $bestmap = definitions_non_fundamental(\%defs);
  delete @defs{keys %$bestmap};
  %defs = %{ _extract_objects(\%defs, $args) };
  %defs = %{ _extract_array_simple(\%defs, $args) };
  my (@fixups, %view2real);
  %defs = %{ _fixup_addProps(\%defs) };
  %defs = %{ _absorb_nonobject(\%defs) };
  my $def2relationalid = _decide_id_fields(\%defs);
  for my $name (sort keys %defs) {
    my ($table, $thesefixups) = _def2table($name, $defs{$name}, $schema, 0, \%view2real, $def2relationalid, $args);
    push @fixups, @$thesefixups;
  }
  my ($newfixups) = _make_many2many(\@fixups, $schema, $def2relationalid, $args);
  for my $fixup (@$newfixups) {
    _fk_hookup($schema, @{$fixup}{qw(from fromkey to tokey required)}, \%view2real);
  }
  1;
}

=encoding utf-8

=head1 NAME

SQL::Translator::Parser::OpenAPI - convert OpenAPI schema to SQL::Translator schema

=begin markdown

# PROJECT STATUS

| OS      |  Build status |
|:-------:|--------------:|
| Linux   | [![Build Status](https://travis-ci.org/mohawk2/SQL-Translator-Parser-OpenAPI.svg?branch=master)](https://travis-ci.org/mohawk2/SQL-Translator-Parser-OpenAPI) |

[![CPAN version](https://badge.fury.io/pl/SQL-Translator-Parser-OpenAPI.svg)](https://metacpan.org/pod/SQL::Translator::Parser::OpenAPI) [![Coverage Status](https://coveralls.io/repos/github/mohawk2/SQL-Translator-Parser-OpenAPI/badge.svg?branch=master)](https://coveralls.io/github/mohawk2/SQL-Translator-Parser-OpenAPI?branch=master)

=end markdown

=head1 SYNOPSIS

  use SQL::Translator;
  use SQL::Translator::Parser::OpenAPI;

  my $translator = SQL::Translator->new;
  $translator->parser("OpenAPI");
  $translator->producer("YAML");
  $translator->translate($file);

  # or...
  $ sqlt -f OpenAPI -t MySQL <my-openapi.json >my-mysqlschema.sql

  # or, applying an overlay:
  $ perl -MHash::Merge=merge -Mojo \
    -e 'print j merge map j(f($_)->slurp), @ARGV' \
      t/06-corpus.json t/06-corpus.json.overlay |
    sqlt -f OpenAPI -t MySQL >my-mysqlschema.sql

=head1 DESCRIPTION

This module implements a L<SQL::Translator::Parser> to convert
a L<JSON::Validator::OpenAPI> specification to a L<SQL::Translator::Schema>.

It uses, from the given API spec, the given "definitions" to generate
tables in an RDBMS with suitable columns and types.

To try to make the data model represent the "real" data, it applies heuristics:

=over

=item *

to remove object definitions considered non-fundamental; see
L<Yancy::Util/definitions_non_fundamental>.

=item *

for definitions that have C<allOf>, either merge them together if there
is a C<discriminator>, or absorb properties from referred definitions

=item *

creates object definitions for any properties that are an object

=item *

creates object definitions for any properties that are an array of simple
OpenAPI types (e.g. C<string>)

=item *

creates object definitions for any objects that are
C<additionalProperties> (i.e. freeform key/value pairs), that are
key/value rows

=item *

absorbs any definitions that are in fact not objects, into the referring
property

=item *

injects foreign-key relationships for array-of-object properties, and
creates many-to-many tables for any two-way array relationships

=back

=head1 ARGUMENTS

=head2 snake_case

If true, will create table names that are not the definition names, but
instead the pluralised snake_case version, in line with SQL convention. By
default, the tables will be named after simply the definitions.

=head1 PACKAGE FUNCTIONS

=head2 parse

Standard as per L<SQL::Translator::Parser>. The input $data is a scalar
that can be understood as a L<JSON::Validator
specification|JSON::Validator/schema>.

=head1 OPENAPI SPEC EXTENSIONS

=head2 C<x-id-field>

Under C</definitions/$defname>, a key of C<x-id-field> will name a
field within the C<properties> to be the unique ID for that entity.
If it is not given, the C<id> field will be used if in the spec, or
created if not.

This will form the ostensible "key" for the generated table. If the
key used here is an integer type, it will also be the primary key,
being a suitable "natural" key. If not, then a "surrogate" key (with a
generated name starting with C<_relational_id>) will be added as the primary
key. If a surrogate key is made, the natural key will be given a unique
constraint and index, making it still suitable for lookups. Foreign key
relations will however be constructed using the relational primary key,
be that surrogate if created, or natural.

=head2 C<x-view-of>

Under C</definitions/$defname>, a key of C<x-view-of> will name another
definition (NB: not a full JSON pointer). That will make C<$defname>
not be created as a table. The handling of creating the "view" of the
relevant table is left to the CRUD implementation. This gives it scope
to use things like the current requesting user, or web parameters,
which otherwise would require a parameterised view. These are not widely
available.

=head2 C<x-artifact>

Under C</definitions/$defname/properties/$propname>, a key of
C<x-artifact> with a true value will indicate this is not to be stored,
and will not cause a column to be created. The value will instead be
derived by other means. The value of this key may become the definition
of that derivation.

=head2 C<x-input-only>

Under C</definitions/$defname/properties/$propname>, a key of
C<x-input-only> with a true value will indicate this is not to be stored,
and will not cause a column to be created. This may end up being merged
with C<x-artifact>.

=head1 DEBUGGING

To debug, set environment variable C<SQLTP_OPENAPI_DEBUG> to a true value.

=head1 AUTHOR

Ed J, C<< <etj at cpan.org> >>

=head1 LICENSE

Copyright (C) Ed J

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<SQL::Translator>.

L<SQL::Translator::Parser>.

L<JSON::Validator::OpenAPI>.

=cut

1;
