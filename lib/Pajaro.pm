# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

# Portions derived from Clojure and ClojureScript, Copyright (c) Rich Hickey, EPL 1.0

package Pajaro;

# type system relies on 'builtin' for true, false, created_as_string, is_bool, etc.
use experimental 'builtin';
use strict;
use warnings;
no warnings 'experimental::builtin';

# In Pajaro, deep Perl recursion is routine (protocol dispatch, seq
# walking), so Perl's depth-100 "Deep recursion" warning is not
# helpful.  Claude says furthermore: the warning "is raised from
# inside pp_goto for the `goto &impl` tail call in protocol dispatch,
# and Carp::Always's __WARN__ handler then calls caller() on that
# half-built frame, which segfaults perl."
no warnings 'recursion';

# do not warn about Vars mapped into Perl packages that do not use them:
no warnings 'once';

use B;
use File::Basename qw(dirname);
use Data::Dumper qw(Dumper);
use File::Spec;
use File::Path;
use FileHandle ();
use Hash::Util::FieldHash qw(fieldhash);
use Math::BigRat;
use IO::Handle;
use Scalar::Util qw'refaddr reftype';
use POSIX qw();
use Pajaro::Munge::SourceFilter;
use Pajaro::Munge qw(munge);
use Pajaro::Hierarchy;
use Pajaro::Hierarchy::Tools;
use Pajaro::ToStringHandle;
use Pajaro::Murmur3;

###--- Global variables to be injected from command line parameters

# $COMPILE_PATH - where to put compiled cljpl.pl files
our $COMPILE_PATH;

# $PATH - Directories to search for *.cljpl files (colon-separated)
our $PATH;

# $VERBOSE - Whether to shout (used as initial value for dynamic Var C<*verbose*>)
our $VERBOSE;

#our $DIRECT_LINKING = 0;

###--- Value utilities

# Marks value as read-only
sub '-ro!' {
    &Internals::SvREADONLY(\$_[0], 1);
    $_[0]
}

sub _type_name_of_known_scalar_number {
    my $F = B::svref_2object(\$_[0])->FLAGS;   # \$_[0], not a copy
    # Bug: -0.0 should be a Double even if it has IOK since the int version lost the sign.
    if ($F & B::SVf_IOK) {
	'Pajaro.Long' # encompasses signed and unsigned. see also B::SVf_IVisUV
    }
    elsif ($F & B::SVf_NOK) {
	'Pajaro.Double'
    }
    else {
	die("We don't know what kind of number this is")
    }
}

sub _scalarNumType { # type name, or undef if evidently not a scalar number
    # returns Long if more than one flag is set.
    # See also 'int?', 'double?'
    if (builtin::created_as_number($_[0])) {
	_type_name_of_known_scalar_number($_[0])
    }
    else {
	undef
    }
}

# identical?( X, Y ) - Whether X and Y are the same object
# This is promoted to a Var belows
sub 'identical?' {
    my $x = shift;
    my $y = shift;
    my $ret;
    if (!defined($x)) { ## nil
        $ret = !defined($y);
    }
    elsif (!defined($y)) { ## nil
        $ret = builtin::false;
    }
    elsif(ref($x) && ref($y)) { ## references
        $ret = refaddr($x)==refaddr($y);
    }
    elsif(!!ref($x) != !!ref($y)) { ## disprove by truthiness
        $ret = builtin::false;
    }
    elsif(builtin::created_as_string($x) != builtin::created_as_string($y)) { ## disprove by stringiness
	$ret = builtin::false;
    }
    elsif((_scalarNumType($x)//'') ne (_scalarNumType($y)//'')) {
	$ret = builtin::false;
    }
    else {
        # Scalars get the benefit of the doubt
        $ret = "$x" eq "$y";
    }
    return $ret ? builtin::true : builtin::false;
}

###--- Object system

=pod

Pajaro's blessed objects are an array, in hopes of being a little
faster than a hash.

These packages/classes will implement various protocols.  Protocols
will be introduced below.  In the meantime, the packages/classes
implement the necessary methods without making a formal link to the
protocol. They also append to a hash of pending protocol extensions.

=cut

# Predeclarations of protocols implemented - to be linked up below
our %LATER_declare_protocol_satisfied;

###--- Base class for things that cache a hash code

=pod

The Pajaro::AHash base class owns array slot 0 and
caches the hash-code there.

Classes that C<@ISA> AHash should provide a _hash method
(to compute the hash without using the cache) and claim to
implement IHash.

=cut

{
    package Pajaro::AHash;

    # Slot 0 is for caching the hash code
    use constant { AHASH_SLOT => 0 };

    sub new_abstract {
        my $this = +[undef];
        return $this;
    }

    # IHash
    sub hash {
        my $this = shift;
        if (!defined($$this[Pajaro::AHash::AHASH_SLOT])) {
            $$this[Pajaro::AHash::AHASH_SLOT] =
                $this->_hash();
        }
        return $$this[Pajaro::AHash::AHASH_SLOT];
    }

    sub _clear_hash {
        my $this = shift;
        undef $$this[Pajaro::AHash::AHASH_SLOT];
    }
}

###--- Base classes for things that have metadata

=pod

The Pajaro::AMeta base class owns array slot 1. Metadata is set by the
constructor. Metadata should be undef or an instance of Pajaro::COWMap.
Mix in Pajaro::AResetMeta or Pajaro::AWithMeta if metadata is changeable.

=cut

{
    package Pajaro::AMeta;
    our @ISA = qw(Pajaro::AHash);

    $Pajaro::LATER_declare_protocol_satisfied{''.__PACKAGE__}=+['clojure.core.IMeta'];

    # Slot 1 is for metadata
    use constant { AMETA_SLOT => 1 };

    our $EMPTY_META = undef; # preliminary because COWMap does not exist yet

    sub new_abstract {
        my $meta = shift;
        my $this = Pajaro::AHash::new_abstract();
        $$this[AMETA_SLOT] = ($meta // $EMPTY_META);
        return $this;
    }

    sub meta { # IMeta of AMeta
        my $this = shift;
        return $$this[AMETA_SLOT];
    }
}

{
    package Pajaro::AResetMeta;
    our @ISA=qw(Pajaro::AMeta);

    $Pajaro::LATER_declare_protocol_satisfied{''.__PACKAGE__}=+['clojure.core.IResetMeta'];

    sub new_abstract {
        return Pajaro::AMeta::new_abstract(@_);
    }

    sub 'reset-meta!' { # IResetMeta of AResetMeta
        my $this = shift;
        my $meta = shift; # optional
        $$this[Pajaro::AMeta::AMETA_SLOT] = $meta;
        return $meta;
    }
}

=pod

An AWithMeta object must satisfy ICloneable in addition to the IWithMeta
that it gets from AWithMeta.

=cut

{
    package Pajaro::AWithMeta;
    our @ISA=qw(Pajaro::AMeta);

    $Pajaro::LATER_declare_protocol_satisfied{''.__PACKAGE__}=+['clojure.core.IWithMeta'];

    sub new_abstract {
        return Pajaro::AMeta::new_abstract(@_);
    }

    sub 'with-meta' { # IWithMeta of AWithMeta
        my $this = shift;
        my $meta = shift;
        my $ret = $this->clone();
        $$ret[Pajaro::AMeta::AMETA_SLOT] = $meta;
        return $ret;
    }
}

###--- Type system

=pod

Perl builtin types and OO packages alike are represented by a Pajaro::Type
object. A type's name is Clojureish - dot-segmented.

=cut

{
    package Pajaro::Type;
    our @ISA = qw(Pajaro::AMeta);
    $Pajaro::LATER_declare_protocol_satisfied{''.__PACKAGE__}=
        +[qw(clojure.core.IMeta clojure.core.INamed clojure.core.IPr clojure.core.IPrint clojure.core.IHash clojure.core.IEquiv)];

    # Slot 2 is for metadata
    use constant { ATYPE_NAME_SLOT => 2 };

    sub new {
        my $class = shift;
        my $meta = shift;
        my $nm = shift;
        my $this = Pajaro::AMeta::new_abstract($meta);
        if ($nm =~ /::/) { die "type name should not be a Perl pkg like $nm" }
        $$this[ATYPE_NAME_SLOT] = $nm;
        return bless $this, $class;
    }

    sub name { # INamed of Type
        my $this = shift;
        return $$this[ATYPE_NAME_SLOT];
    }

    sub '-pr-str' { # IPr of Type
        my $this = shift;
        return ('Type<' . $$this[ATYPE_NAME_SLOT] . '>');
    }

    *_print_str = \*_pr_str; # IPrint of Type

    sub _hash { # IHash of Type
        my $this = shift;
        Pajaro::Murmur3::hasheqString($$this[ATYPE_NAME_SLOT]);
    }

    sub '-equiv' { # IEquiv of Type
        my $this = shift;
        my $other = shift;
        return (ref($this) eq ref($other)
                && $$this[ATYPE_NAME_SLOT] eq $$other[ATYPE_NAME_SLOT])
            ? builtin::true
            : builtin::false;
    }
}

# Clojure ns or type name (dot-segmented) -> Perl package (:: separated) Lossy.
sub _namespace_munge {
    my $s = shift;
    my @segments = split(/[.]/,$s);
    join('::', map(munge($_),@segments))
}

# Perl ::-sep pkg name or primitive ref to Clojure dot-sep ns or type name.
# Undef -> Empty string.
# One-word Perl ref name -> 'Perl.'+the name
sub _perl_pkg_name_to_clj {
    my $pkgname = shift;
    if (!defined($pkgname)) { $pkgname=''; }
    if ($pkgname ne '' && $pkgname !~ /::/ && $pkgname !~ /[.]/) {
        $pkgname = 'Perl.'.$pkgname;
    }
    else {
        $pkgname =~ s/::/./g;
    }
    return $pkgname;
}

# A Clojure package name backformed from a Perl package has underscores.
# Should some or all of them be hyphens instead? The first definition wins.
our %norm_clj_type_name_hyphens; # name-with-underscores => name-with-hyphens

# In Perl the type name is more fundamental than the type object (a ref is a string)...

our %_type_name_RTN = (); # ref=>type name

sub _type_name {
    my $x = shift;
    my $rf = ref($x);
    my $ret;
    if ($rf) {
	if (exists($_type_name_RTN{$rf})) {
	    $ret = $_type_name_RTN{$rf};
	}
	else {
	    $ret = _perl_pkg_name_to_clj($rf);
	    my $without_hyphens = $ret; $without_hyphens =~ s/-/_/g;
	    if (exists($norm_clj_type_name_hyphens{$without_hyphens})) {
		if ($ret ne $norm_clj_type_name_hyphens{$without_hyphens}) {
		    $ret = $norm_clj_type_name_hyphens{$without_hyphens};
		}
	    }
	    $_type_name_RTN{$rf} = $ret;
	}
    }
    else {
        if (!defined($x)) {
            $ret = '';
        }
        elsif (builtin::created_as_string($x)) {
            $ret = 'Pajaro.String';
        }
        elsif (builtin::created_as_number($x)) {
            $ret = _type_name_of_known_scalar_number($x);
        }
        elsif (builtin::is_bool($x)) {
            $ret = 'Pajaro.Boolean';
        }
        elsif ('GLOB' eq Scalar::Util::reftype(\$x)) {
            $ret = 'Perl.GLOB';
        }
        else {
            die "Ref is empty; not a string, number, boolean... what is $x?";
        }
    }
    return $ret;
}

###--- Type sniffing

sub 'boolean?' {
    my $x = shift;
    # Should agree with 'Pajaro.Boolean' eq _type_name($_[0])
    builtin::is_bool($x)
}

sub 'string?' {
    my $x = shift;
    # Should agree with 'Pajaro.String' eq _type_name($_[0])
    builtin::created_as_string($x)
}

sub 'int?' { # spans signed and unsigned int; exclusive of double?
    # Important: look at flags of \$_[0], accessing (not copying) the arg.
    # Should agree with 'Pajaro.Long' eq _type_name($_[0])
    !!(builtin::created_as_number($_[0])
       && B::svref_2object(\$_[0])->FLAGS & B::SVf_IOK)
}

sub 'uint?' { # subset of int?
    # Important: look at flags of \$_[0], accessing (not copying) the arg.
    my $flags;
    !!(builtin::created_as_number($_[0])
       && ($flags=B::svref_2object(\$_[0])->FLAGS) & B::SVf_IOK
       && $flags & B::SVf_IVisUV)
}

sub 'double?' { # exclusive of int?
    my $flags;
    # Should agree with 'Pajaro.Double' eq _type_name($_[0])
    !!(builtin::created_as_number($_[0])
       && ($flags=B::svref_2object(\$_[0])->FLAGS) & B::SVf_NOK
       && !($flags & B::SVf_IOK))
}

###--- Type interning

our %TYPES; # interned Clojure-ish type name => Type object of the same name

=pod _find_type( TYPE_NAME )

Type object for the type name (a string or undef), undef if none interned.
The udefined type name is treated as an empty string.

=cut

sub _find_type {
    # In hot loops. So skip they sanity checking:
    #die('arity') unless (@_ == 1);
    my $nm = shift; # string or undef, which is treated as empty string
    if (!defined($nm)) { $nm=''; }
    #if ($nm =~ /::/) { die "_find_type requires a type name, not Perl pkg like $nm" }
    if (exists($TYPES{$nm})) {
        return $TYPES{$nm};
    }
    else {
        return undef;
    }
}

sub _find_type_or_die {
    my $nm = shift;
    my $ret = _find_type($nm);
    if (!defined($ret)) {
        die "There is no type named \"$nm\"";
    }
    return $ret;
}

=pod _intern_type( TYPE_NAME )

Type object for the type name (a Clojure dot-qualified string or
undef); a freshly interned Type object if the type name had not yet
been interned.  The udefined type name is treated as an empty string.

=cut

# Clojure name -> hyphen-normed name -> (memoized: munge to Perl; probe for Perl variable which is blessed and isa Pajaro::Type; otherwise make a Pajaro::Type for it)
sub _intern_type {
    # In hot loops. So skip they sanity checking:
    #die('arity') unless (@_ == 1);
    my $nm = shift; # string (undef treated as empty string)
    #if ($nm =~ /::/) { die "_intern_type requires a type name, not Perl pkg like $nm" }
    #if (!defined($nm)) {die "oops"; $nm=''; }

    my $without_hyphens = $nm; $without_hyphens =~ s/-/_/g;
    # A hyphenated spelling and its underscored twin (as backformed from a
    # Perl package name) are one type; whichever spelling had a hyphen is
    # the one remembered, and the underscored spelling must map to it too.
    if (exists($norm_clj_type_name_hyphens{$without_hyphens})) {
        $nm = $norm_clj_type_name_hyphens{$without_hyphens};
    }
    elsif ($without_hyphens ne $nm) {
        $norm_clj_type_name_hyphens{$without_hyphens} = $nm;
    }
    my $ret;
    if (exists($TYPES{$nm})) {
        $ret = $TYPES{$nm};
    }
    else {
        # Extant Type/Protocol Or a twin for a Perl package.
        {
            my $pl = _namespace_munge($nm);
            # basename_pl := the LAST ::-separated segment of perl name
            my @segments = split(/::/,$pl);
            my $basename_pl = pop(@segments);
            my $ppkg = join('::',@segments);
            if ($ppkg ne $pl) { # i.e., a name of >1 ::-separated segment
                my $basename_pl = substr($pl, length($ppkg)+2);
                no strict 'refs';
                if (exists(${"${ppkg}::"}{$basename_pl})) {
                    # There is such a variable
                    if (defined(*{"${ppkg}::$basename_pl"}{SCALAR})) {
                        my $x = ${"${ppkg}::$basename_pl"};
                        if (Scalar::Util::blessed($x)
                            && $x->isa(Pajaro::Type::)) {
                            $ret=$x;
                        }
                    }
                }
            }
            if (!$ret) {
                $ret = new Pajaro::Type(undef, $nm);
            }
        }
        $TYPES{$nm} = $ret;
    }
    return $ret;
}

# Remove a name from the TYPES cache
sub _untern_type { # opposite of _intern_type
    die('arity') unless (@_ == 1);
    my $nm = shift; # string (undef treated as empty string)
    if ($nm =~ /::/) { die "_untern_type requires a type name, not Perl pkg like $nm" }
    if (!defined($nm)) { $nm=''; }
    delete $TYPES{$nm}
}

# Finds interned type, or interns a type if such a package actually exists.
# Type name must be dot-qualified
sub _find_type_backfill {
    die('arity') unless (@_ == 1);
    my $nm = shift; # string or undef, which is treated as empty string
    if (!defined($nm)) { $nm=''; }
    if (exists($TYPES{$nm})) {
        return $TYPES{$nm};
    }
    else {
        my $typ_pl = _namespace_munge($nm);
        $typ_pl =~ s/^Perl:://;
        (my $typ_pl_parent, my $typ_pl_relative) = ($typ_pl =~ /(^.*?)([^:]+)$/);
        {
            if (!$typ_pl_parent) { $typ_pl_parent = 'main::' }
            no strict 'refs';
            if (exists(${"${typ_pl_parent}"}{"${typ_pl_relative}::"})) {
                return _intern_type($nm);
            }
        }
        return undef;
    }
}

=pod _perl_pkg_name_to_type( PACKAGE_NAME )

Type object representing the package name.
A package name C<X> that does not contain C<::> is interpreted as C<Perl::X>.
Interns a new Type object if the package name had been unrepresented.

=cut

sub _perl_pkg_name_to_type {
    my $pkgname = shift;
    return _intern_type(_perl_pkg_name_to_clj($pkgname));
}

=pod type( X )

Interned type object representing the type of C<X> (an instance).
If C<X> is nil, nil is returned.

=cut

# This (sub type) is promoted to a Var below
sub type {
    my $x = shift;
    _intern_type(_type_name($x))
}

###--- Number primitives and class tree

# The old $x/1 trick does not reliably make a double of $x.
sub _mk_double {    # Claude: always a clean NV, whatever the magnitude
    my $x = shift;  # copy: pack reads its argument as an NV and would pollute the caller's
    unpack('d', pack('d', $x))
}

{
    package Pajaro::Number; # supertype for Math::BigRat and Pajaro::Double

    sub same_type { # the caller must already have ensured both were created-as-number
	if (B::svref_2object(\$_[0])->FLAGS & B::SVf_IOK
	    && B::svref_2object(\$_[1])->FLAGS & B::SVf_IOK) {
	    builtin::true
	}
	elsif (B::svref_2object(\$_[0])->FLAGS & B::SVf_NOK
	    && B::svref_2object(\$_[1])->FLAGS & B::SVf_NOK) {
	    builtin::true
	}
	elsif (ref($_[0]) && ref($_[1]) && (ref($_[0]) eq ref($_[1])))  {
	    builtin::true
	}
	else {
	    builtin::false
	}
    }

    sub cast_long { # Claude
	my $x = shift;
	my ($lo, $hi) = ($Pajaro::Long::MIN_VALUE, $Pajaro::Long::SIGNED_MAX_VALUE); # copies: comparisons pollute their operands
	if (ref($x)) {                               # Math::BigInt / BigFloat / BigRat
	    my $i = $x->as_int();                    # truncates toward zero
	    die "Value out of range for long: $x (< $lo or > $hi)" if ($i < $lo || $i > $hi);
	    return 0 + $i->numify();
	}
	return 0 if $x != $x;                        # NaN: Clojure (long ##NaN) => 0
	my $i = CORE::int($x);
	return $Pajaro::Long::MIN_VALUE if $i == $lo;   # int() gives an NV for exactly -2**63; return a fresh IV
	die "Value out of range for long: $x" if $i < $lo || $i > $hi;
	$i
    }

    sub cast_double {
	my $x = shift;
	if (ref($x)) { # if it's a Number, it better be a Math::BigInt/BigFloat/BigRat
	    Pajaro::_mk_double($x->numify())
	}
	else {
	    Pajaro::_mk_double($x)
	}
    }
    sub cast_bigint {
	my $x = shift;
	if (ref($x)) { # if it's a Number, it better be a Math::BigInt/BigFloat/BigRat
	    $x->as_int()
	}
	else {
	    Math::BigInt->new($x)
	}
    }
    sub cast_bigfloat {
	my $x = shift;
	if (ref($x)) { # if it's a Number, it better be a Math::BigInt/BigFloat/BigRat
	    $x->as_float()
	}
	else {
	    Math::BigFloat->new($x)
	}
    }
    sub cast_bigrat {
	my $x = shift;
	if (ref($x)) { # if it's a Number, it better be a Math::BigInt/BigFloat/BigRat
	    $x->as_rat()
	}
	else {
	    Math::BigRat->new($x)
	}
    }

    # REF_WIDTH for direction of promotion when harmonizing operands for math.
    # Double must be considered the widest because it is lossy.
    # That is, casting Double up to BigFloat would be meaningless.
    our %REF_WIDTH = ('Pajaro.Long' => 0,
		      'Math.BigInt' => 1,
		      'Math.BigRat' => 2,
		      'Math.BigFloat' => 3,
		      'Pajaro.Double' => 4);

    our %REF_CAST = ('Pajaro.Long' => \&cast_long,
		     'Pajaro.Double' => \&cast_double,
		     'Math.BigInt' => \&cast_bigint,
		     'Math.BigFloat' => \&cast_bigfloat,
		     'Math.BigRat' => \&cast_bigrat);

    # Throws if either is nil, otherwise returns +[a,b] with each upcast from unsigned-int to BigInt and then one upcast to match the type of the other if they were of different types.
    sub promote {
        my $a = shift;
        my $b = shift;
	my $au = !defined($a);
        my $bu = !defined($b);
        if ($au || $bu) {
            die "nil does not work as a number"
        }
	else {
	    if(Pajaro::uint_QMARK_($a)) {$a=cast_bigint($a)}
	    if(Pajaro::uint_QMARK_($b)) {$b=cast_bigint($b)}
	    my $ar = Pajaro::_type_name($a);
	    my $br = Pajaro::_type_name($b);
	    my $aw = $REF_WIDTH{$ar};
	    my $bw = $REF_WIDTH{$br};
	    if (!defined($aw) || !defined($bw)) {
		die "Unsuitable types $ar, $br for $a, $b"
	    }
	    if ($aw > $bw) {
		return +[$a, &{$REF_CAST{$ar}}($b)]
	    }
	    elsif ($aw < $bw) {
		return +[&{$REF_CAST{$br}}($a), $b]
	    }
	    else {
		return +[$a, $b]
	    }
	}
    }
}

# Math::BigRat->config("downgrade", "Math::BigInt"); # oops, causes Math::BigRat 2-arg constructor to crash

{
    package Pajaro::Double;
    our @ISA = qw(Pajaro::Number);

    sub binf { # match the static method name of Math::BigInt, BigFloat, BigRat
	my $sign = shift // '';
	if ('-' eq $sign) {
	    -builtin::inf()
	}
	else {
	    builtin::inf()
	}
    }
    sub 'infinite?' { # coincidental with clojure.core public function name
	my $n = shift;
	($n == builtin::inf()) || ($n == -builtin::inf())
    }
    sub bnan { # match the static method name of Math::BigInt, BigFloat, BigRat
	builtin::nan()
    }
    sub 'NaN?' { # coincidental with clojure.core public function name
	my $n = shift;
	$n != $n
    }
    sub 'neg?' {
	my $n = shift;
	$n < 0.0
    }
    sub _perl_float_literal {
	my $x = shift;
	# Claude: "shortest-round-trip method... That's what Java and Clojure do"
	for my $p (15 .. 17) {
	    my $s = sprintf("%.${p}g", $x);
	    $s .= '.0' if $s !~ /[.e]/;   # %g dropped the point: 42 -> 42.0
	    return $s if $s == $x;      # converts back to exactly the same double
	}
	die "Oops"
    }
    sub pr_str {
	my $x = shift;
	if (NaN_QMARK_($x)) {
	    '##NaN'
	}
	elsif (infinite_QMARK_($x)) {
	    if (neg_QMARK_($x)) {
		'##-Inf'
	    }
	    else {
		'##Inf'
	    }
	}
	else {
	    _perl_float_literal($x)
	}
    }
}

{
    package Pajaro::Long;
    # This package holds a place in the hierarchy for Long.
    # But there is no Perl OO method dispatch for Longs, e.g., 42->infinite_QMARK_.
    # Therefore this type's methods are not directly protocol implementations.
    # They are just coincidentally named, e.g., infinite?

    our @ISA = qw(Pajaro::Number);

    our $MAX_VALUE = (~0);
    our $SIGNED_MAX_VALUE = $MAX_VALUE >> 1;
    our $MIN_VALUE = -$SIGNED_MAX_VALUE - 1;

    sub binf { # match the static method name of Math::BigInt, BigFloat, BigRat
	my $sign = shift // '';
	die 'Pajaro.Long overflowed to infinity';
    }
    sub 'infinite?' { # coincidental with clojure.core public function name
	#my $n = shift;
	#my $sign = shift;
	builtin::false
    }
    sub bnan { # match the static method name of Math::BigInt, BigFloat, BigRat
	die 'Pajaro.Long overflowed to NaN';
    }
    sub 'NaN?' { # coincidental with clojure.core public function name
	#my $n = shift;
	builtin::false
    }
    sub 'neg?' {
	my $n = shift;
	$n < 0
    }
    sub pr_str {
	my$n=shift;
	"$n"
    }
}

# Math::BigXyz will be subtypes of Pajaro::Number in the Clojure
# global hierarchy, not in the @ISA sense.

###--- Global hierarchy

{
    # super-primitive hierarchy that can operate without using any protocol methods
    # (such as equiv or hash), so it can be used by the protocol mechanism.
    package Pajaro::TypeHierarchy;

    our @ISA = qw(Pajaro::Hierarchy);

    sub new {
        my $class = shift;
        bless Pajaro::Hierarchy->new(), $class;
    }

    sub _encode {
        my $this = shift;
        my $x = shift;
        # Convert string or nil to Pajaro::Type:
        if (defined($x) && !ref($x)) {
            # should be a Perl package name
            if ($x =~ /[.]/) { die "Unexpected dot in what should be a Perl package name, $x" }
            $x=Pajaro::_perl_pkg_name_to_clj($x);
            $x=Pajaro::_intern_type($x);
        }
        elsif (!defined($x)) {
            $x=Pajaro::_intern_type('');
        }
        # Encode:
        my $ret;
        if ('Pajaro::Type' eq ref($x)) {
            $ret = '.'.Pajaro::_perl_pkg_name_to_clj($x->name());
        }
        elsif ('Pajaro::Symbol' eq ref($x)) {
            $ret = "'".clojure::core::pr_str($x);
        }
        elsif ('Pajaro::Keyword' eq ref($x)) {
            $ret = clojure::core::pr_str($x);
        }
        else {
            die("global-hierarchy stores only Pajaro::Type, Pajaro::Symbol, Pajaro::Keyword, but not $x");
        }
        $ret;
    }

    sub _decode {
        my $this = shift;
        my $x = shift;
        my $sigil;
        my $detail;
        ($sigil,$detail)=($x =~ /^([.:'])(.*)/);
        my $ret;
        if ($sigil eq '.') {
            $ret = Pajaro::_intern_type($detail);
        }
        elsif ($sigil eq "'") {
            my @p = split(m(/), $detail, 2);
            $ret = clojure::core::symbol(@p);
        }
        elsif ($sigil eq ':') {
            my @p = split(m(/), $detail, 2);
            $ret = clojure::core::keyword(@p);
        }
        $ret;
    }
}

sub _copy_hierarchy {
    my $dest = shift;
    my $src = shift;
    for my $deriv (@{$src->_derivations()}) {
        $dest = $dest->_derive(@{$deriv});
    }
    return $dest;
}

###--- Var

our $UNBOUND = bless(+{}, 'Pajaro::Var::Unbound');
sub _is_the_unbound { my $x = shift; 'Pajaro::Var::Unbound' eq ref($x) }

# var? is promoted to a Var below
sub 'var?' {
    my $x = shift;
    'Pajaro::Var' eq ref($x);
}

{
    package Pajaro::Var;
    our @ISA = qw(Pajaro::AResetMeta);

    $Pajaro::LATER_declare_protocol_satisfied{''.__PACKAGE__}=
        +['clojure.core.IVar', 'clojure.core.IDeref', 'clojure.core.IFn', 'clojure.core.IHash', 'clojure.core.IEquiv', 'clojure.core.IMeta', 'clojure.core.IResetMeta'];

    use constant { NAMED_NS_SLOT=>2, NAMED_NAME_SLOT=>3, VAR_REFERENT_SLOT=> 4,
    VAR_DYNAMIC_SET_SLOT=>5, VAR_DYNAMIC_REFERENT_SLOT=>6, VAR_WATCHERS_SLOT=>7};

    # Alert! (binding [...]) dynamically assigns to the VAR_DYNAMIC_*_SLOT.

    sub assign_name_ns_meta {
        # no-op, pending definition of Namespace and Keyword
        # will initialize :name metadata (an unqualified Symbol)
        # will initialize :ns metadata (in Clojure, it is a Namespace object)
    }

    sub new {
        my $class = shift;
        my $meta = shift; # preliminary: ^:dynamic is not yet supported
        my $namespace = shift; # string, Clojure-format, dot-separated
        my $name = shift; # string. Clj format, NOT MUNGED
        my $referent_given = (0 != @_);
        my $referent = shift; # code or scalar/ref: initial root binding of the Var
        if (!$referent_given) {
            $referent = $Pajaro::UNBOUND;
        }
        die if ref($namespace);
        die if $namespace =~ /::/;
        die if $namespace =~ /_COLON__COLON_/;
        die if ref($name);
        die unless $namespace;
        die unless $name;

        my $self = Pajaro::AResetMeta::new_abstract($meta);
        $$self[NAMED_NS_SLOT] = $namespace;
        $$self[NAMED_NAME_SLOT] = $name;
        $$self[VAR_REFERENT_SLOT] = $referent;
	$$self[VAR_DYNAMIC_SET_SLOT] = undef;
	$$self[VAR_DYNAMIC_REFERENT_SLOT] = undef;
	$$self[VAR_WATCHERS_SLOT] = undef;
        my $this = bless($self, $class);
        $this->assign_name_ns_meta($name, $namespace);

        if ($referent ## sanity check
            && 'Pajaro::Var' eq ref($referent)
            && $$self[NAMED_NAME_SLOT] eq $$referent[NAMED_NAME_SLOT]
            && $$self[NAMED_NS_SLOT] eq $$referent[NAMED_NS_SLOT]) {
            die "Circular?";
        }

        return $this;
    }

    sub get_name {
        my $this = shift;
        $$this[NAMED_NAME_SLOT]
    }

    sub get_namespace {
        my $this = shift;
        $$this[NAMED_NS_SLOT]
    }

    # IVar for Var
    sub '-set-root-binding!' {
        my $this = shift;
        my $x = shift;

        if ($x ## sanity check
            && 'Pajaro::Var' eq ref($x)
            && $$this[NAMED_NAME_SLOT] eq $$x[NAMED_NAME_SLOT]
            && $$this[NAMED_NS_SLOT] eq $$x[NAMED_NS_SLOT]) {
            die "Circular?";
        }

	my $old = $$this[VAR_REFERENT_SLOT];

        $$this[VAR_REFERENT_SLOT] = $x;

	$this->_notify_watches($old, $x);

        $x
    }
    sub _var_get {
        my $this = shift;
	if ($$this[VAR_DYNAMIC_SET_SLOT]) {
	    $$this[VAR_DYNAMIC_REFERENT_SLOT]
	}
	else {
	    $$this[VAR_REFERENT_SLOT]
	}
    }
    *var_get = \*_var_get;

    # Var's IDeref
    *deref = \*_var_get;

    # Var's IFn
    sub '-code' {
        my $this = shift;
        my $referent = _var_get($this);
        my $rref = ref($referent);
        # IFn protocol dispatch uses this code, so we can't use it here
        if ('CODE' eq $rref) {
            return $referent;
        }
        elsif (Scalar::Util::blessed($referent) && $referent->can('_code')) {
            return \&{$referent->_code()};
        }
        else {
            undef
        }
    }

    # IHash of Var
    sub _hash {
        my $this = shift;
        Pajaro::Murmur3::hashSymbol
            ($$this[NAMED_NS_SLOT],
             $$this[NAMED_NAME_SLOT]);
    }

    # IEquiv of Var
    sub '-equiv' {
        my $this = shift;
        my $other = shift;
        return (clojure::core::var_QMARK_($other)
                && $$this[NAMED_NAME_SLOT] eq $$other[NAMED_NAME_SLOT]
                && $$this[NAMED_NS_SLOT] eq $$other[NAMED_NS_SLOT]);}

    # for IWatchable of Var
    sub _notify_watches {
	undef # filled in below after maps are in good shape
    }

    use overload '&{}' => '_code', 'fallback' => 1;

    # Scalar deref overload allows usage as a filehandle with print
    use overload '${}' => 'deref', 'fallback' => 1;
}

# X, or (deref X) if X is precisely a Pajaro::Var.
sub _deref_if_var {
    my $x = shift;
    ('Pajaro::Var' eq ref($x)) ? $x->deref() : $x;
}

sub _Var_to_perl {
    my $v = shift;
    '$' . _namespace_munge($v->get_namespace()) . '::' . munge($v->get_name());
}

# CODE reference from a CODE or Var
sub _ifn_code {
    my $x = shift;
    if ('CODE' eq ref($x)) { return $x; }
    elsif (Scalar::Util::blessed($x) && $x->can('_code')) { return $x->_code(); }
    else {return undef;}
}

###--- Interning a Var

=pod

You can intern a function named 'import' but it won't be placed in the
var name's CODE slot in the namespace's Perl symbol table. That slot
is reserved for use by Perl's require/use mechanism.  Perl's `import`
callback upon a `require` or `use` in any namespace simply returns 1.

user> (defn import [] 42)
#'user/import
user> (import)
42
user> (perl-eval "&user::import")
1
user> (perl-eval "&{$user::import}")
42

=cut

sub _perl_import_callback {
    1;
}

# Bestows a name on an anonymous sub and stores it and a given var in
# the Perl symbol table; except, that if the Var is named "import",
# stores our package-import callback in the code slot.
sub _name_and_intern_a_sub {
    my $code = shift;
    my $perlpkg = shift;
    my $perlnm = shift;
    my $var = shift;
    my $fullname = $perlpkg . '::' . $perlnm;
    no warnings 'redefine';
    no strict 'refs';
    if (defined($code) && 'CODE' eq ref($code)) {
	my $subname = Sub::Util::subname($code);
	my $import_kluge = ($fullname =~ m,::import$,);
	if ($subname =~ /::__ANON__/) {
	    Sub::Util::set_subname($fullname, $code);
	}
	*{$fullname} = ($import_kluge ? \&_perl_import_callback : $code);
    }
    ${$fullname} = $var;
}

our $INTERN_HOWTO_REGISTER_WITH_NS = sub{}; # to be revised below

sub _intern1 {
    my $ns = shift; # un-munged namespace string
    my $nm_meta = shift; # metadata from the name symbol
    my $nm = shift; # un-munged symbol-name string
    my $init = (0 != @_);
    my $value = shift;
    my $perlpkg = _namespace_munge($ns);
    my $perlnm = munge($nm);
    my $code = _ifn_code($value);
    my $fullname = $perlpkg . '::' . $perlnm;
    my $import_kluge = ($fullname =~ m,::import$,);
    ## -- if intern1 was not given a value, and the slot exists, leave alone
    # (refer...) stores another namespace's Vars in our symbol table.
    # Store a Var as-is, regardless of its native namespace; wrap a non-Var in a new Var.
    my $new_var = ('Pajaro::Var' eq ref($value))
	? $value
	: new Pajaro::Var($nm_meta, $ns, $nm, $init ? $value : $UNBOUND);
    no strict 'refs';
    my $extant_var = (exists(${"${perlpkg}::"}{$perlnm})
                      ? ${"${perlpkg}::$perlnm"}
                      : undef);
    if ($extant_var && ('Pajaro::Var' ne ref($extant_var))) {
        undef $extant_var;
    }
    # Do not clobber the value of an interned Var from another namespace
    if ($extant_var && !($extant_var->_equiv($new_var))) {
        undef $extant_var;
    }
    if (!$init && $extant_var) {
        # important: do not clobber metadata it might already have. This is the case with the transpiler interning the name before transpiling the meta or init value
        $extant_var
    }
    elsif ($init && $extant_var && 'Pajaro::Var' eq ref($value)) {
        &{$INTERN_HOWTO_REGISTER_WITH_NS}($ns, $nm, $new_var);
	_name_and_intern_a_sub($code, $perlpkg, $perlnm, $value);
    }
    elsif ($init && $extant_var && !('Pajaro::Var' eq ref($value))) {
        $extant_var->_set_root_binding_BANG_($value);
        $extant_var->reset_meta_BANG_($nm_meta);
        $extant_var->assign_name_ns_meta();
	_name_and_intern_a_sub($code, $perlpkg, $perlnm, $extant_var);
    }
    elsif (!$init && !$extant_var) { # declaring name only: unbound value
        &{$INTERN_HOWTO_REGISTER_WITH_NS}($ns, $nm, $new_var);
        ${$fullname} = $new_var
    }
    elsif ($init && !$extant_var) {
        # (refer...) stores another namespace's Vars in our symbol table.
        # Store a Var as-is, regardless of its native namespace; wrap a non-Var in a new Var.
        &{$INTERN_HOWTO_REGISTER_WITH_NS}($ns, $nm, $new_var);
	_name_and_intern_a_sub($code, $perlpkg, $perlnm, $new_var);
    }
}

=pod _intern( NAMESPACE-NAME, NAME-OR-SYMBOL [, VALUE] )

Finds or creates a var named by the symbol name in the namespace
ns (which can be a string or a namespace), setting its root binding
to val if supplied. The namespace must exist. The var will adopt any
metadata from the name symbol.  Screws the Var into the Perl package
symbol table. If the Var holds a CODE reference, populates the CODE
glob slot as well. Returns the Var.

=cut

sub _intern { # preliminary: ns is namespace name only (not object)
    my $ns = shift; # un-munged
    my $nm = shift; # un-munged name string or Symbol
    my $has_value = (0 != @_);
    my $value = shift;
    my $nm_meta;
    if (ref($nm)) {
        my ($_nm_cite, $nm_user_meta) = _citation_and_user_meta($nm);# forward!
        $nm_meta = $nm_user_meta;
        $nm = clojure::core::name($nm);
    }
    if ($has_value) {
        _intern1($ns, $nm_meta, $nm, $value)
    }
    else {
        _intern1($ns, $nm_meta, $nm)
    }
}

###--- Hierarchy

_intern('clojure.core','global-hierarchy', new Pajaro::TypeHierarchy());

our %_find_method_impl_RPM; # ref=>protocol=>method=>CODE
our %_find_method_impl_TPM; # type=>protocol=>method=>CODE
our %_satisfies_TP; # type=>protocol=>boolean

sub _find_method_impl_clear_cache {
    %_find_method_impl_RPM=();
    %_find_method_impl_TPM=();
    %_satisfies_TP=()
}

# Adds all loaded Perl packages to $global_hierarchy
sub _freshen_global_hierarchy {
    $clojure::core::global_hierarchy->_set_root_binding_BANG_
        (_copy_hierarchy
         ($clojure::core::global_hierarchy->deref(),
          (Pajaro::Hierarchy::Tools::perl_hierarchy
           (new Pajaro::TypeHierarchy()))));
    _find_method_impl_clear_cache();
}

_freshen_global_hierarchy();

# Perl undef, String, Number, Boolean, CODE, HASH, and ARRAY extend UNIVERSAL:
# This loop interns types and establishes a relationship to UNIVERSAL:
for my $example (undef,
                 'fudge',
                 42,
		 42.5,
                 builtin::true,
                 sub { 'quux' },
                 +{},
                 +[]) {
    $clojure::core::global_hierarchy->deref()->_derive
        (type($example),
        _find_type_or_die('Perl.UNIVERSAL'));
}

# The above interned lots of built-in types, but not the type of nil (an edge case because (type nil) is nil)
$clojure::core::global_hierarchy->deref()->_derive
    (_intern_type(''),
     _find_type_or_die('Perl.UNIVERSAL'));

_intern_type('Perl.GLOB'); # TBD should Perl.GLOB derive from UNIVERSAL?

# Patch Math::BigInt, BigFloat as a subclass of Pajaro.Number:
$clojure::core::global_hierarchy->deref()->_derive
    (_find_type_or_die('Math.BigInt'),
     _find_type_or_die('Pajaro.Number'));
$clojure::core::global_hierarchy->deref()->_derive
    (_find_type_or_die('Math.BigFloat'),
     _find_type_or_die('Pajaro.Number'));
$clojure::core::global_hierarchy->deref()->_derive
    (_find_type_or_die('Math.BigRat'),
     _find_type_or_die('Pajaro.Number'));

=pod ancestors( [HIERARCHY,] TYPE )

Immediate and indirect parents of TYPE. Preliminary: global hierarchy
only.

=cut

_intern('clojure.core', 'ancestors',
	sub {
	    my $h;
	    my $t;
	    if (@_==2) {
		$h=shift;
		$t=shift;
	    }
	    elsif (@_==1) {
		$h = $clojure::core::global_hierarchy->deref();
		$t = shift; # a Pajaro::Type object or undef
	    }
	    $h->_ancestors($t);
	});

=pod instance?( TYPE, X )

True if C<X> is an instance of C<TYPE> (directly or indirectly),
otherwise false. For this purpose, protocols are I<not> types;
see C<satisfies?>.

=cut

_intern('clojure.core', 'instance?',
        sub {
            my $cls = shift; # a Pajaro::Type object or undef
            die 'Expected a Pajaro::Type, got '.ref($cls)
                unless (!defined($cls) || ('Pajaro::Type' eq ref($cls)));
            my $x = shift;
            my $xt = type($x); # a Pajaro::Type object or undef
            my $ret;
            if (&clojure::core::identical_QMARK_($cls, $xt)) {
                $ret=builtin::true;
            }
            else {
                my $a=$clojure::core::global_hierarchy->deref()->_ancestors($xt);
                my @g=grep($_ eq $cls, @{$a});
                $ret=(@g ? builtin::true : builtin::false);
            }
            return $ret;
        });

###--- Protocols (plumbing)

{
    package Pajaro::Protocol;
    our @ISA = qw(Pajaro::Type);
    $Pajaro::LATER_declare_protocol_satisfied{''.__PACKAGE__}=
        +[qw(clojure.core.IMeta clojure.core.INamed clojure.core.IPr clojure.core.IPrint clojure.core.IHash clojure.core.IEquiv)];

    # Inherits IHash/IEquiv implementation from Type

    # Slot 1 is for metadata
    # Slot 2 is for the type name
    use constant { APROTOCOL_METHODS => 3 };
    use constant { APROTOCOL_EXTENSIONS => 4 };
    use constant { APROTOCOL_DISPATCH_NS => 6 };

    sub new {
        die "arity" unless 4==@_;
        my $class = shift;
        my $meta = shift;
        my $nm = shift;
        my $methods = shift; # HASH: { method name => docstring }
        my $this = new Pajaro::Type(undef, $nm);

        my $dispatch_ns = $nm;
        $dispatch_ns =~ s/[.][^.]*?$//;

        $$this[APROTOCOL_METHODS] = $methods;
        $$this[APROTOCOL_EXTENSIONS] = +{}; # type-name => method-name => CODE
        $$this[APROTOCOL_DISPATCH_NS] = $dispatch_ns;
        return bless $this, $class;
    }

    sub methods_for_type_name {
        my $this = shift;
        my $type_name = shift;
        if(exists($$this[APROTOCOL_EXTENSIONS]{$type_name})) {
            $$this[APROTOCOL_EXTENSIONS]{$type_name};
        }
    }

    sub set_methods_for_type_name {
        my $this = shift;
        my $type_name = shift;
        my $methods = shift; # HASH: { methodname => CODE }
        if ($type_name =~ /::/) { die "set_methods_for_type_name requires a type name, not Perl pkg like $type_name" }
        $$this[APROTOCOL_EXTENSIONS]{$type_name} = $methods;
    }

    sub dispatch_ns {
        my $this = shift;
        $$this[APROTOCOL_DISPATCH_NS]
    }
}

# Object's ref if non-empty => Proto name => method name => CODE

our $PROTOCOLS_ARE_CONNECTED = 0;

sub _find_method_impl {
    my $object = shift; # may be undef
    my $protocol = shift; # a Protocol object
    my $method = shift;
    my $rv;
    my $ref_of_object = ref($object);
    my $pn=Scalar::Util::refaddr($protocol); # faster stringify than ->name()
    if ($ref_of_object) { # falsey does not distinguish scalar types
        $rv=$_find_method_impl_RPM{$ref_of_object}{$pn}{$method};
        if($rv) {
            return $rv;
        }
    }

    my $tn = _type_name($object);

    $rv=$_find_method_impl_TPM{$tn}{$pn}{$method};
    if($rv) {
        return $rv;
    }

    my $tms = $protocol->methods_for_type_name($tn);

    # 1. Object's type or supertype provides the method:
    # Check blessed(), not ref(); HASH & ARRAY have ref but not ->can()
    if (($tms || !$PROTOCOLS_ARE_CONNECTED)
        && Scalar::Util::blessed($object)) {
        my $pmethod = munge($method);
        my $f = $object->can($pmethod);
        if (defined($f)) {
            $_find_method_impl_RPM{$ref_of_object}{$pn}{$method}=$f;
            return $f;
        }
    }
    # 2. (Not implemented): Object's metadata directs the method:
    # 3. The protocol is extended to the Object's type or a supertype:
    {
        if ($tms) {
            my $f = $$tms{$method};
            if ($f) {
                $_find_method_impl_TPM{$tn}{$pn}{$method}=$f;
                return $f;
            }
            else {
                die "The method map does not include $method";
            }
        }
        # Look for an implementation among type's ancestors.
        # In case hierarchy is outdated, try twice, freshening in-between.
        my $t = _intern_type($tn);
        for (my $attempt = 0; $attempt < 2; $attempt++) {
            my $types = clojure::core::ancestors($t);
            for my $type (@{$types}) {
                my $tna = $type->name();
                $tms = $protocol->methods_for_type_name($tna);
                if ($tms) {
                    if (!('HASH' eq ref($tms))) { die "Strange. Perl pkg ".(ref($object))." lacks method $method but base-class $tna should fully satisfy protocol ".$protocol->name()}
                    my $f = $$tms{$method};
                    if ($f) {
                        $_find_method_impl_TPM{$tn}{$pn}{$method}=$f;
                        return $f;
                    }
                    else {
                        die "The method map does not include $method";
                    }
                }
            }
            # If nothing found, maybe the hierarchy is outdated? try once more
            _freshen_global_hierarchy();
        }
    }
    die "No implementation of protocol ".$protocol->name()." method $method for ".(ref($object) || 'unblessed')." ".clojure::core::pr_str(type($object))." ".(defined($object)?$object:'undef');
}

=pod _setup_protocol( DOT-QUALIFIED-NAME, METHODS )

Interns a type object and defines dispatch methods in the Perl package
munged from DOT-QUALIFIED. The type object is named NAME. METHODS is a
Perl hash-map of method name to TBD maybe a docstring.

=cut

sub __setup_protocol_intern_method {
    my $protocol = shift;
    my $method = shift;
    my $code = sub {goto \&{_find_method_impl($_[0], $protocol, $method)}};
    _intern($protocol->dispatch_ns(), $method, \&{$code});
}

sub _setup_protocol {
    my $nm = shift; # string in Clojure interop dot-qualified format
    my $methods = shift; # HASH: { method name => docstring }
    my $protocol = new Pajaro::Protocol(undef, $nm, $methods);
    my $proto_perl_full = _namespace_munge($nm);
    # Stow a Type object at my_pkg::$NAME, so _intern_type's backfill (below)
    # recognizes and reuses this same Protocol object instead of manufacturing
    # a plain Type in its place:
    {
        no strict 'refs';
        ${$proto_perl_full} = $protocol;
    }
    # Stow method dispatch fns in my_pkg:
    for my $method (CORE::keys(%{$methods})) {
        __setup_protocol_intern_method($protocol, $method);
    }
    # Intern type name
    _untern_type($nm);
    _intern_type($nm);

    # Also intern the protocol name as a Var (like def), registering it in
    # its namespace, so it can be found unqualified after
    # (refer-clojure)/(refer ...), not just fully-qualified. This overwrites
    # my_pkg::$NAME (stowed above) to hold the Var instead of the bare
    # Protocol; qualified-symbol resolution (Transpiler.pm) already
    # derefs a Var found there, and _extend_type/satisfies? unwrap a Var too.
    my ($local_name) = ($nm =~ /([^.]+)$/);
    _intern($protocol->dispatch_ns(), $local_name, $protocol);
}

=pod _extend_protocol( PROTOCOL, TYPE [, METHODS] )

Registers implementations of PROTOCOL's methods for TYPE.
PROTOCOL and TYPE are Type objects. METHODS is a Perl hash-map
of method name to CODE reference. If METHODS is omitted
then TYPE must implement PROTOCOL's methods by Perl OO.

=cut

sub _extend_protocol { # preliminary: extend to real types, not protocols
    my $protocol = shift; # Protocol object
    my $type = shift; # Type object -or- Perl::package::
    my $methods = shift; # HASH: { methodname => CODE } - optional - if missing, the type's packages should implement the methods
    die "Not a protocol?".$protocol.ref($protocol)
        unless ('Pajaro::Protocol' eq ref($protocol));
    # Translate type to typename:
    my $tn;
    if (!ref($type)) { # upgrade Perl package to Type object
        $type =~ s/::$//;
        no strict 'refs';
        if (!defined(*{"${type}::"}{HASH})) {
            die "Not a type object";
        }
        $tn = _perl_pkg_name_to_clj($type);
    }
    else {
        $tn = $type->name();
    }
    # Attach methods to type name:
    $protocol->set_methods_for_type_name($tn, $methods // builtin::true);
    # Clear cached dispatch fn based on a prior extension or superclass
    _find_method_impl_clear_cache();
    builtin::true; # don't return whatever nonsense came from set_methods
}

=pod satisfies?( PROTOCOL, OBJECT )

true if OBJECT satisfies PROTOCOL, otherwise false

=cut
_intern('clojure.core','satisfies?',
        sub {
            my $protocol = shift; # Protocol object (or a Var referring to one)
            die unless $protocol;
            $protocol = _deref_if_var($protocol);
	    my $pn = $protocol->name();
            my $object = shift; # object
	    my $tn0 = (_type_name($object) // '');
	    if(exists($_satisfies_TP{$tn0}{$pn})) {
		return $_satisfies_TP{$tn0}{$pn};
	    }
            my $tms = $protocol->methods_for_type_name($tn0);
            if ($tms) {
                return $_satisfies_TP{$tn0}{$pn} = builtin::true;
            }
            else {
                # Look for an implementation among type's ancestors.
		my $t = _intern_type($tn0);
                my $types = clojure::core::ancestors($t);
                 for my $type (@{$types}) {
                    my $tn1 = $type->name();
                    $tms = $protocol->methods_for_type_name($tn1);
                    if ($tms) {
                        return $_satisfies_TP{$tn0}{$pn} = builtin::true;
                    }
                }
            }
            return $_satisfies_TP{$tn0}{$pn} = builtin::false;
        });

=pod _extend_type( TYPE [, PROTOCOL [, METHODS]]... )

Extends each of the PROTOCOLs (given as a Protocol object) to the
given TYPE (a Type object).  METHODS is a hash
of method name (string) to CODE but if the method implementations of a
protocol are all inline in the type (via Perl OO) then METHODS can be
omitted.

=cut

sub _extend_type {
    my $type = shift; # Type object or Perl::Pkg::
    die "Type must be a Pajaro::Type not ".ref($type)." of $type"
        unless 'Pajaro::Type' eq ref($type);
    while(@_) {
        my $protocol = _deref_if_var(shift); # Protocol object (or a Var referring to one)
        die "Protocol must be a Pajaro::Protocol not ".ref($protocol)." of $protocol"
            unless 'Pajaro::Protocol' eq ref($protocol);
        my $methods = (0<@_) ? $_[0] : undef;
        my $methods2;
        if ('HASH' eq ref($methods)) {
            shift; # Perl HASH method-name => CODE
            $methods2= $methods;
        }
        else {
            $methods2 = builtin::true;
        }
        _extend_protocol($protocol, $type, $methods2);
    }
}

###--- Protocols ...

_setup_protocol('clojure.core.IHierarchy',
		+{'-derivations'=>'?',
		      '-derive'=>'?',
		      '-underive'=>'?',
		      '-ancestors'=>'?',
		      '-descendants'=>'?'});
_setup_protocol('clojure.core.ICloneable', +{'clone'=>'?'});
_setup_protocol('clojure.core.IComparable', +{'compare'=>'?'});
_setup_protocol('clojure.core.ICount', +{'count'=>'?'});
_setup_protocol('clojure.core.ICounted', +{});
_setup_protocol('clojure.core.IDeref', +{'deref'=>'?'});
_setup_protocol('clojure.core.IFn', +{'-code'=>'?'});
_setup_protocol('clojure.core.IHash', +{'hash'=>'?'});
_setup_protocol('clojure.core.IEquiv', +{'-equiv'=>'?'});
_setup_protocol('clojure.core.IMeta', +{'meta'=>'?'});
_setup_protocol('clojure.core.INamed', +{'name'=>'?'});
_setup_protocol('clojure.core.INaN',
		+{#'binf'=>'?',
		      'infinite?'=>'?',
		      #'bnan'=>'?',
			  'NaN?'=>'?',
		'neg?'=>'?'});
_setup_protocol('clojure.core.IPr', +{'-pr-str'=>'?'});
_setup_protocol('clojure.core.IPrint', +{'-print-str'=>'?'});
_setup_protocol('clojure.core.IResetMeta', +{'reset-meta!'=>'?'});
_setup_protocol('clojure.core.IVar',
		+{'var-get'=>'?',
		      '-set-root-binding!'=>'?' # set-root-binding! returns x
		});
_setup_protocol('clojure.core.IWithMeta', +{'with-meta'=>'?'});

# Extend protocols to the types that registered themselves earlier.
for my $t (CORE::keys(%LATER_declare_protocol_satisfied)) {
    my @pp = @{$LATER_declare_protocol_satisfied{$t}};
    _extend_type(_intern_type(_perl_pkg_name_to_clj($t)),
                 map(_find_type_or_die($_), @pp));
}

$PROTOCOLS_ARE_CONNECTED = 1;

_extend_type(_intern_type('Pajaro.Var'),
             $clojure::core::IPr, +{'-pr-str'=>sub {
                 my $this=shift;
                 "#'". $this->get_namespace() . '/' . $this->get_name()
                           }},
             $clojure::core::IPrint, +{'-print-str'=>sub {
                 my $this=shift;
                 "#'". $this->get_namespace() . '/' . $this->get_name()
                           }});

_extend_type(_intern_type('Pajaro.TypeHierarchy'), $clojure::core::IHierarchy);

###--- Connect numeric protocols, which enable equivalence checks

_extend_type(_intern_type('Math.BigInt'),# of which BigFloat, BigRat are subtypes
	     $clojure::core::INaN,
	     +{'infinite?'=>sub{my$n=shift;!!($n->is_inf())},
		   'NaN?'=>sub{my$n=shift;!!($n->is_nan())},
		   'neg?'=>sub{my$n=shift;!!($n->is_negative())}
	     });
_extend_type(_intern_type('Pajaro.Long'),
	     $clojure::core::INaN,
	     +{'infinite?'=>sub{my$n=shift;Pajaro::Long::infinite_QMARK_($n)},
		   'NaN?'=>sub{my$n=shift;Pajaro::Long::NaN_QMARK_($n)},
		   'neg?'=>sub{my$n=shift;Pajaro::Long::neg_QMARK_($n)}
	     });
_extend_type(_intern_type('Pajaro.Double'),
	     $clojure::core::INaN,
	     +{'infinite?'=>sub{my$n=shift;Pajaro::Double::infinite_QMARK_($n)},
		   'NaN?'=>sub{my$n=shift;Pajaro::Double::NaN_QMARK_($n)},
		   'neg?'=>sub{my$n=shift;Pajaro::Double::neg_QMARK_($n)}
	     });

###--- clojure.core functions wrapping protocol dispatch methods

_intern('clojure.core', 'equiv',
        sub {
            my $a = shift;
            my $b = shift;
            if (&clojure::core::satisfies_QMARK_($clojure::core::IEquiv, $a)) {
                clojure::core::_equiv($a, $b);
            }
            else {
                clojure::core::_equiv($b, $a);
            }});

###--- Namespace

_setup_protocol('clojure.core.INamespace', +{'ns-name'=>'?'});

{
    package Pajaro::Namespace;
    our @ISA = qw(Pajaro::AResetMeta);

    # Slot 1 is for metadata
    use constant { NAME_SLOT => 2 };
    use constant { CONTENT_SLOT => 3 };
    use constant { ALIAS_SLOT => 4 };

    sub new {
        my $class = shift;
        my $meta = shift;
        my $nm = shift;
        my $this = Pajaro::AMeta::new_abstract($meta);
        $$this[NAME_SLOT] = $nm; # Clojure dot-qualified notation
        $$this[CONTENT_SLOT] = +{}; # Clojure name (string) => Var (for an interned symbol) or Symbol-of-pkg (Clojure notation for an imported class)
        $$this[ALIAS_SLOT] = +{}; # Clojure name (string) => Namespace object
        return bless $this, $class;
    }

    sub '-pr-str' { # IPr of Namespace
        my $this = shift;
        return ('Namespace<' . $$this[NAME_SLOT] . '>');
    }

    sub '-print-str' { # IPrint of Namespace
        my $this = shift;
        $$this[NAME_SLOT]
    }

    sub _hash { # IHash of Namespace
        my $this = shift;
        Pajaro::Murmur3::hasheqString($$this[NAME_SLOT]);
    }

    sub '-equiv' { # IEquiv of Namespace
        my $this = shift;
        my $other = shift;
        return (ref($this) eq ref($other)
                && $$this[NAME_SLOT] eq $$other[NAME_SLOT])
            ? builtin::true
            : builtin::false;
    }

    sub get_name {
        my $this = shift;
        return $$this[NAME_SLOT];
    }

    sub mapVarNameToVarOrSymbol {
        my $this = shift;
        my $varname = shift;
        my $payload = shift;
        $$this[CONTENT_SLOT]{$varname}=$payload;
        $this
    }

    sub unmapVarName {
        my $this = shift;
        my $varname = shift;
        my $payload = shift;
        delete $$this[CONTENT_SLOT]{$varname};
        $this
    }

    sub contents {
        my $this = shift;
        $$this[CONTENT_SLOT]
    }

    sub aliases {
        my $this = shift;
        $$this[ALIAS_SLOT]
    }

    # INamespace added later because it requires Symbol
}

_extend_type(_intern_type('Pajaro.Namespace'),
             map(_find_type_or_die($_), qw(clojure.core.IMeta clojure.core.IResetMeta clojure.core.IPr clojure.core.IPrint clojure.core.IHash clojure.core.IEquiv)));

our %NAMESPACES; # interned namespace name => Namespace object of the same name

=pod _setup_ns( DOT-QUALIFIED-NS-NAME )

Interns a metadata-carrying Namespace object for the dot-qualified
name.

=cut

sub _setup_ns {
    my $dqname = shift;
    if (!exists($NAMESPACES{$dqname})) {
        $NAMESPACES{$dqname} = new Pajaro::Namespace(undef, $dqname);
    }
    return $NAMESPACES{$dqname};
}

_intern('clojure.core', '-the-ns', # preliminary: accepts a string (or symbol) and creates ns if it did not exist
        sub {
            my $x = shift;
            if ('Pajaro::Namespace' eq ref($x)) {
                return $x;
            }
            else {
                return _setup_ns("$x"); # "convert" possible symbol to name
            }
        });

$INTERN_HOWTO_REGISTER_WITH_NS = sub {
    my $ns = shift; # un-munged namespace string
    my $nm = shift; # un-munged symbol-name string
    my $value = shift;
    if (ref($value) ne 'Pajaro::Var'
        && ref($value) ne 'Pajaro::Symbol') {
        die "Strange, expected to intern a Var or Symbol for $nm but got $value ".ref($value);
    }
    &clojure::core::_the_ns($ns)->mapVarNameToVarOrSymbol($nm, $value)
};

_intern('clojure.core','all-ns',
	sub{clojure::core::seq(+[values(%NAMESPACES)])}); # forward!

###--- clojure.core Namespace

our $PERC_NS = _setup_ns('clojure.core');

{
    my $tmp = \&identical_QMARK_;
    _intern('clojure.core', 'identical?', $tmp);
}
{
    my $tmp = \&type;
    _intern('clojure.core', 'type', $tmp);
}
{
    my $tmp = \&var_QMARK_;
    _intern('clojure.core', 'var?', $tmp);
}
{
    my $tmp = \&boolean_QMARK_;
    _intern('clojure.core', 'boolean?', $tmp);
}
{
    my $tmp = \&string_QMARK_;
    _intern('clojure.core', 'string?', $tmp);
}
{
    my $tmp = \&int_QMARK_;
    _intern('clojure.core', 'int?', $tmp);
}
{
    my $tmp = \&uint_QMARK_;
    _intern('clojure.core', 'uint?', $tmp);
}
{
    my $tmp = \&double_QMARK_;
    _intern('clojure.core', 'double?', $tmp);
}

# Transfer clojure::core:: package contents to clojure.core namespace:
{
    no strict 'refs';
    for my $nm (CORE::keys %{'clojure::core::'}) {
        if ($nm !~ /^_/) {
            my $fullname = 'clojure::core::' . $nm;
            if (defined(*{$fullname}{SCALAR}) # cf find-var
                && 'Pajaro::Var' eq ref(${$fullname}))
            {
                my $v = ${$fullname};
                if ('clojure.core' eq $v->get_namespace()) {
                    $PERC_NS->mapVarNameToVarOrSymbol($v->get_name(), $v);
                }
            }
        }
    }
}

_intern('clojure.core', '*ns*', $PERC_NS);


###--- Type casts

_intern('clojure.core', 'boolean', sub {
    my $x = shift;
    if (!defined($x)) {
        builtin::false
    }
    elsif (&clojure::core::boolean_QMARK_($x) && !$x) {
        builtin::false
    }
    else {
        builtin::true
    }
        });

our $K_TRUE_STR = 'true'; &'-ro!'($K_TRUE_STR);
our $K_FALSE_STR = 'false'; &'-ro!'($K_FALSE_STR);

###--- Protocols extended to scalar and Perl built-in types

_extend_type(type('a-string'),
             $clojure::core::IComparable, +{'compare'=>sub{
                 my $this = shift;
                 my $x = shift;
                 if (!defined($x)) { 1 }
                 elsif (builtin::created_as_string($x)) {
                     $this cmp $x
                 }
                 else {
                     die "Not comparable with String"
                 }
                                   }},
             $clojure::core::ICount, +{'count'=>sub{length($_[0])}},
             #$clojure::core::ICounted, +{}, # String has a count, but is not Counted!
             $clojure::core::IEquiv, +{'-equiv'=>sub{
                 if (!defined($_[1])) { builtin::false }
                 elsif (!builtin::created_as_string($_[1])) { builtin::false }
                 else { "$_[0]" eq "$_[1]" }
                              }},
             $clojure::core::IHash, +{'hash'=>sub{return Pajaro::Murmur3::hasheqString($_[0])}},
             $clojure::core::IMeta, +{'meta'=>sub{undef}},
             $clojure::core::INamed, +{'name'=>sub{"$_[0]"}},
             $clojure::core::IPr, +{'-pr-str'=>sub{B::perlstring($_[0])}},
             $clojure::core::IPrint, +{'-print-str'=>sub{"$_[0]"}} # try to isolate the original from modifications
    );

_extend_type
    (_find_type('Perl.GLOB'),
      $clojure::core::IPr, +{'-pr-str'=>sub{"$_[0]"}},
      $clojure::core::IPrint, +{'-print-str'=>sub{"$_[0]"}}
     );

sub _pr_num {
    my $x=shift;
    if ($x != $x) { # a Long can never be NaN or Inf. Avoid polluting with the comparison
        '##NaN'
    }
    elsif ($x == builtin::inf()) {
        '##Inf'
    }
    elsif ($x == -builtin::inf()) {
        '##-Inf'
    }
    else {
        "$x"
    }
}

sub _anyNumberType {
    my $x = shift;
    # Should match (isa? (type x) Pajaro.Number)
    builtin::created_as_number($x)
	|| 'Math::BigInt' eq ref($x)
	|| 'Math::BigFloat' eq ref($x)
	|| 'Math::BigRat' eq ref($x)
}

_extend_type(_intern_type('Pajaro.Number'),
             $clojure::core::IComparable, +{'compare'=>sub{
                 my $this = shift;
                 my $x = shift;
                 if (!defined($x)) { 1 }
		 elsif (!_anyNumberType($x)) { die "Cannot compare number with non-number" }
                 else {
                     $this <=> $x
                 }
                                   }},
             $clojure::core::IEquiv, +{'-equiv'=>sub{
		 my $a=shift; my$b=shift;
		 if (!_anyNumberType($b)) {
		     builtin::false
		 }
		 else {
		     my $at = _type_name($a);
		     my $bt = _type_name($b);
		     # Long and BigInt are in same equality partition
		     # a) both Long
		     if ('Pajaro.Long' eq $at && 'Pajaro.Long' eq $bt) {
			 $a == $b
		     }
		     # b) one is Long and one is BigInt
		     elsif ('Pajaro.Long' eq $at && 'Math.BigInt' eq $bt) {
			 $b == $a # important: the wider one on the left
		     }
		     elsif ('Pajaro.Long' eq $bt && 'Math.BigInt' eq $at) {
			 $a == $b # important: the wider one on the left
		     }
		     # c) both are BigInt
		     elsif ('Math.BigInt' eq $at && 'Math.BigInt' eq $bt) {
			 $a == $b
		     }

		     # Double, BigFloat, BigRat are distinct equality partitions
		     # d) both are BigFloat
		     elsif ($at eq $bt) {
			 $a == $b
		     }
		     else {
			 builtin::false
		     }
		 }
				       }},
	     # (It would be better to hash Double without ignoring its fractional part while maintaining hash equal to int hash for whole-number, within-int-range Doubles)
             $clojure::core::IHash,
	     +{'hash'=>sub
	       {
		   my$x=shift;
		   # ##NaN and ##Inf and ##-Inf as in Clojure
		   if (clojure::core::NaN_QMARK_($x)) {
		       2146959360 # from Clojure
		   }
		   elsif (clojure::core::infinite_QMARK_($x)) {
		       if (clojure::core::neg_QMARK_($x)) {
			   -1048576 # from Clojure
		       }
		       else {
			   2146435072 # from Clojure
		       }
		   }
		   else {
		       my$xt=_type_name($x);
		       # Long and BigInt are in same equality partition
		       if ('Pajaro.Long' eq $xt) {
			   if ($x <= $Pajaro::Long::SIGNED_MAX_VALUE) {
			       Pajaro::Murmur3::hashLong($x)
			   }
			   else {
			       # Treat same as BigInt
			       Pajaro::Murmur3::hasheqString("$x")
			   }
		       }
		       elsif ('Pajaro.Double' eq $xt) {
			   Pajaro::Murmur3::hashDouble($x)
		       }
		       elsif ('Math.BigInt' eq $xt) {
			   if (($x <= $Pajaro::Long::SIGNED_MAX_VALUE)
			       && ($x >= $Pajaro::Long::MIN_VALUE)) {
			       Pajaro::Murmur3::hashLong(CORE::int($x->numify())) # match Clojure int hash since int and BigInt are in same equality partition
			   }
			   else { # Treat same as unsigned integer that's beyond signed-int range
			       Pajaro::Murmur3::hasheqString("$x")
			   }
		       }
		       # BigFloat, BigRat are distinct equality partitions
		       else {
			   Pajaro::Murmur3::hasheqString("$x")
		       }
		   }
	       }},
    );

_extend_type(_intern_type('Pajaro.Long'),
             $clojure::core::IPr, +{'-pr-str'=>\&Pajaro::Long::pr_str},
             $clojure::core::IPrint, +{'-print-str'=>\&Pajaro::Long::pr_str}
    );

_extend_type(_intern_type('Pajaro.Double'),
             $clojure::core::IPr, +{'-pr-str'=>\&Pajaro::Double::pr_str},
             $clojure::core::IPrint, +{'-print-str'=>\&Pajaro::Double::pr_str}
    );

sub _mathbig_pr_str {
    my $literalTag=shift; # including the leading '#';;; or empty string
    my $sigil=shift; # or empty string
    my $n=shift;
    my $special;
    if (clojure::core::NaN_QMARK_($n)) {
	$special="NaN"
    }
    elsif (clojure::core::infinite_QMARK_($n)) {
	if (clojure::core::neg_QMARK_($n)) {
	    $special="-Inf"
	}
	else {
	    $special="Inf"
	}
    }
    if ($special) {
	if ($literalTag) {
	    $literalTag.' "'.$special.'"'
	}
	else {
	    $special
	}
    }
    else {
	$n->bstr().$sigil
    }
}

_extend_type(_intern_type('Math.BigInt'),
             $clojure::core::IPr,
	     +{'-pr-str'=>sub{my$x=shift;_mathbig_pr_str('#Math.BigInt','N',$x)}},
             $clojure::core::IPrint,
	     +{'-print-str'=>sub{my$x=shift;_mathbig_pr_str('','',$x)}}
    );

_extend_type(_intern_type('Math.BigFloat'),
	     $clojure::core::IPr,
	     +{'-pr-str'=>sub{my$x=shift;_mathbig_pr_str('#Math.BigFloat','M',$x)}},
             $clojure::core::IPrint,
	     +{'-print-str'=>sub{my$x=shift;_mathbig_pr_str('','',$x)}}
    );

_extend_type(_intern_type('Math.BigRat'),
	     $clojure::core::IPr,
	     +{'-pr-str'=>sub{my$x=shift;_mathbig_pr_str('#Math.BigRat','',$x)}},
             $clojure::core::IPrint,
	     +{'-print-str'=>sub{my$x=shift;_mathbig_pr_str('','',$x)}}
    );

_extend_type(_perl_pkg_name_to_type('UNIVERSAL'),
             $clojure::core::IPr,
             +{'-pr-str'=>sub {"$_[0]"}},
             $clojure::core::IPrint,
             +{'-print-str'=>sub {"$_[0]"}});


_extend_type(_find_type_or_die(''), # the type of nil
             $clojure::core::IComparable, +{'compare'=>sub{
                 my $this = shift;
                 my $other = shift;
                 defined($other) ? -1 : 0;
                                   }},
             $clojure::core::IHash, +{'hash'=>sub{0}},
             $clojure::core::ICount, +{'count'=>sub{0}},
             $clojure::core::IEquiv, +{'-equiv'=>sub{ !defined($_[1]) }},
             $clojure::core::IPr, +{'-pr-str'=>sub{'nil'}},
             $clojure::core::IPrint, +{'-print-str'=>sub{'nil'}}
    );

_extend_type(type(builtin::true),
             $clojure::core::IEquiv, +{'-equiv'=>sub{
                 if (!defined($_[1])) { builtin::false }
                 elsif (!builtin::is_bool($_[1])) { builtin::false }
                 else {
                     $_[0] == $_[1]
                 }
                              }},
             $clojure::core::IHash, +{'hash'=>sub{return Pajaro::Murmur3::hashLong(int($_[0]))}},
             $clojure::core::IPr, +{'-pr-str'=>sub{$_[0]?'true':'false'}},
             $clojure::core::IPrint, +{'-print-str'=>sub{$_[0]?'true':'false'}}
    );

{
    my $pr_str_func = sub{
        my $this=shift;
        my @slugs=('#perl {');
        my $sep='';
        for my $k (keys(%{$this})) {
            push(@slugs, $sep, clojure::core::_pr_str($k), ' ', clojure::core::_pr_str($$this{$k}));
            $sep=',';
        }
        push(@slugs,'}');
        join('',@slugs) };
    _extend_type(type(+{}),
                 #$clojure::core::IAssociative, +{},
                 $clojure::core::ICount, +{'count'=>sub {my $this=shift; 0+%{$this}}},
                 $clojure::core::ICounted, +{},
                 $clojure::core::IPr, +{'-pr-str'=>$pr_str_func},
                 $clojure::core::IPrint, +{'-print-str'=>$pr_str_func},
        );
}

{
    my $pr_str_func = sub{
        my $this=shift;
        my @slugs=('#perl [');
        my $sep='';
        for my $x (@{$this}) {
            push(@slugs, $sep, clojure::core::_pr_str($x));
            $sep=' ';
        }
        push(@slugs,']');
        join('',@slugs) };
    _extend_type(type(+[]),
                 $clojure::core::ICount, +{'count'=>sub {my $this=shift; 0+@{$this}}},
                 #$clojure::core::ICounted, +{}, ## arrays have count, but are not Counted!
                 $clojure::core::IPr, +{'-pr-str'=>$pr_str_func},
                 $clojure::core::IPrint, +{'-print-str'=>$pr_str_func});
}

sub _printRegexp {
    my $r = shift;
    my $s = "$r";
    # correct for repeated sheathing with (?^: ... )
    if (substr($s, 0, 4) eq '(?^:'
        && substr($s, -1, 1) eq ')') {
        $s=substr($s, 4, -1);
    }
    # escape double quotes
    $s =~ s/"/\\"/g;
    '#"'.$s.'"';
}

_extend_type(type(qr/!/), # Perl.Regexp
             $clojure::core::IEquiv, +{'-equiv'=>sub{return ("$_[0]" eq "$_[1]")}},
             $clojure::core::IHash, +{'hash'=>sub{return Pajaro::Murmur3::hasheqString("$_[0]")}},
             $clojure::core::IMeta, +{'meta'=>sub{undef}},
             $clojure::core::IPr, +{'-pr-str'=>sub{_printRegexp($_[0])}},
             $clojure::core::IPrint, +{'-print-str'=>sub{_printRegexp($_[0])}}
    );

# sub{} is a Clojure function and supports metadata:

fieldhash our %sub_meta; # metadata of a sub
fieldhash our %sub_orig; # the original of a clone of a sub

_intern('clojure.core','-adopt-sub-with-meta',
        sub {
            my $c=shift;
            my $m=shift;
            $sub_meta{$c}=$m;
            $c
        });

_extend_type(type(sub {}),
             $clojure::core::IFn, +{'-code'=>sub{$_[0]}},
             $clojure::core::ICloneable, +{'clone'=>sub{
                 my$x=shift;
                 if (exists($sub_orig{$x})) {
                     sub{goto $sub_orig{$x}}
                 }
                 else {
                     my $r=sub{goto $x};
                     $sub_orig{$r}=$x;
                     $r
                 }
                                  }},
             $clojure::core::IEquiv, +{'-equiv'=>sub {my $this=shift; my$other=shift;
                              refaddr($this)==refaddr($other)}},
             $clojure::core::IHash, +{'hash'=>sub{my$x=shift; refaddr($x)}},
             $clojure::core::IMeta, +{'meta'=>sub{my$x=shift; $sub_meta{$x}}},
             $clojure::core::IWithMeta, +{'with-meta'=>sub{my$x=shift;my$m=shift;my$c=clojure::core::clone($x);$sub_meta{$c}=$m;$c}});

###--- Printing (to a String)

sub _with_out_str { # preliminary: takes a sub, not a block
    my $f = shift;
    my $fh=IO::Handle->new();
    my @s;
    tie *$fh, 'Pajaro::ToStringHandle', sub{push(@s,$_[0])};
    local $$clojure::core::_STAR_out_STAR_[Pajaro::Var::VAR_REFERENT_SLOT] = $fh; # *out*
    &{$f};
    close $fh;
    return join('',@s);
}

# This gets :dynamic metadata below
_intern('clojure.core', '*print-meta*', builtin::false);

_intern('clojure.core','pr-str',
        sub {
            # Any arity
            my @builder;
            for my $x (@_) {
                if ($clojure::core::_STAR_print_meta_STAR_->deref()) {
                    my $m = clojure::core::meta($x);
                    if (clojure::core::seq($m)) {
                        push(@builder, clojure::core::str('^', clojure::core::_pr_str($m)));
                    }
                }
                push(@builder, clojure::core::_pr_str($x));
            }
            return join(' ',@builder);
        });

_intern('clojure.core','print-str',
        sub {
            # Any arity
            my @builder;
            for my $x (@_) {
                push(@builder, clojure::core::_print_str($x));
            }
            return join(' ',@builder);
        });

_intern('clojure.core','str',
        sub {
            # Any arity
            my @builder;
            for my $x (@_) {
                if (defined($x)) {
		    my $a;
                    if (_anyNumberType($x)) {
                        if (clojure::core::infinite_QMARK_($x)) {
                            if (clojure::core::neg_QMARK_($x)) {
                                $a='-Infinity'
                            }
                            else {
                                $a='Infinity'
                            }
                        }
			elsif (clojure::core::NaN_QMARK_($x)) {
			    $a='NaN'
			}
                        else {
                            $a=clojure::core::_print_str($x)
                        }
                    }
                    else {
                        $a=clojure::core::_print_str($x)
                    }
		    push(@builder, $a)
                }
            }
            return join('',@builder);
        });

###--- Equality

_intern('clojure.core','=',sub {
         my @args = @_; # Careful of aliasing
         if (1 == @args) {
             return builtin::true;
         }
         elsif (2 == @args) {
             if (defined($args[0]) ^ defined($args[1])) { # Differing undef'ness
                 return builtin::false;
             }
             elsif (!defined($args[0])) { # Both undef
                 return builtin::true;
             }
             elsif (_anyNumberType($args[0])
		    && clojure::core::NaN_QMARK_($args[0]) # NaN
                    || _anyNumberType($args[1])
		    && clojure::core::NaN_QMARK_($args[1])) {
                 return builtin::false;
             }
             elsif (clojure::core::identical_QMARK_($args[0], $args[1])) { # identical
                 return builtin::true;
             }
             elsif (clojure::core::satisfies_QMARK_($clojure::core::IEquiv, $args[0])) { # IEquiv
                 return clojure::core::_equiv($args[0], $args[1]);
             }
             elsif (clojure::core::seqable_QMARK_($args[0]) # ISeqable
                    && clojure::core::seqable_QMARK_($args[1])) {
                 return _equiv_via_seqable($args[0], $args[1]);
             }
             elsif ($args[0] eq $args[1]) { # Strings
                 return builtin::true;
             }
             else {
		 # TBD how is this different from the case above?
                 return builtin::false;
		 #return clojure::core::boolean("$args[0]" eq "$args[1]");
             }
         }
	 elsif (0==@_) {
	     die "No args passed to =";
	 }
         else {
             my $x = $args[0];
             my $y = $args[1];
             if (clojure::core::_EQ_($x, $y)) {
                 return clojure::core::_EQ_(@args[1..$#args]);
             }
             else {
                 return builtin::false;
             }
         }
        });

_intern('clojure.core','==',sub {
         my @args = @_;
	 if (0 == @args) {
	     die 'ArityException'
	 }
         elsif (1 == @args) {
             return builtin::true;
         }
         elsif (2 == @args) {
	     my ($a,$b)=@args;
	     # promote because Perl says 1N == 1.1M
	     my $p=Pajaro::Number::promote($a,$b);
	     my ($a2,$b2)=@{$p};
	     $a2 == $b2
         }
        });

###--- Collection protocols

_setup_protocol('clojure.core.IAssoc', +{'assoc'=>'?'});
_setup_protocol('clojure.core.IAssociative', +{});
_setup_protocol('clojure.core.ICollection', +{});
_setup_protocol('clojure.core.IConj', +{'-conj'=>'?'});
_setup_protocol('clojure.core.IDisj', +{'disj'=>'?'});
_setup_protocol('clojure.core.IDissoc', +{'dissoc'=>'?'});
_setup_protocol('clojure.core.IDrop', +{'-drop'=>'?'});
_setup_protocol('clojure.core.IEditableCollection', +{'transient'=>'?'});
_setup_protocol('clojure.core.IEmptyable', +{'empty'=>'?'});
_setup_protocol('clojure.core.IFind', +{'find'=>'?'});
_setup_protocol('clojure.core.IIndexed', +{'nth'=>'?'});
_setup_protocol('clojure.core.IKeysVals', +{'keys'=>'?', 'vals'=>'?'});
_setup_protocol('clojure.core.IList', +{});
_setup_protocol('clojure.core.ILookup', +{'contains?'=>'?', 'get'=>'?'});
_setup_protocol('clojure.core.IMap', +{});
_setup_protocol('clojure.core.IMapEntry', +{'key'=>'?', 'val'=>'?'});
_setup_protocol('clojure.core.INamespaced', +{'namespace'=>'?'});
_setup_protocol('clojure.core.INext', +{'-next'=>'?'});
_setup_protocol('clojure.core.IPeek', +{'peek'=>'?'});
_setup_protocol('clojure.core.IPerlArray', +{'-perl-array'=>'?'}); # constant time only, i.e., related to ICounted
_setup_protocol('clojure.core.IReduced', +{});
_setup_protocol('clojure.core.IReversible', +{'-rseq'=>'?'});
_setup_protocol('clojure.core.IFirstRest', +{'-first'=>'?', '-rest'=>'?'});
_setup_protocol('clojure.core.ISeqable', +{'seq'=>'?'});
_setup_protocol('clojure.core.ISequential', +{});
_setup_protocol('clojure.core.ISet', +{});
_setup_protocol('clojure.core.IStack', +{'pop'=>'?'});
_setup_protocol('clojure.core.ITransientAssoc', +{'assoc!'=>'?'});
_setup_protocol('clojure.core.ITransientCollection', +{'persistent!'=>'?'});
_setup_protocol('clojure.core.ITransientConj', +{'-conj!'=>'?'});
_setup_protocol('clojure.core.ITransientDisj', +{'disj!'=>'?'});
_setup_protocol('clojure.core.ITransientDissoc', +{'dissoc!'=>'?'});
_setup_protocol('clojure.core.ITransientStack', +{'pop!'=>'?'});
_setup_protocol('clojure.core.IVector', +{});

_intern('clojure.core', 'coll?', sub{
    my $x = shift;
    if (!defined($x)) { builtin::false }
    else { &clojure::core::satisfies_QMARK_($clojure::core::ICollection, $x)
               || &clojure::core::satisfies_QMARK_($clojure::core::IFirstRest, $x) }
        });

_intern('clojure.core', 'sequential?', sub{
    &clojure::core::satisfies_QMARK_($clojure::core::ISequential, $_[0])
        });

_intern('clojure.core', 'associative?', sub{
    &clojure::core::satisfies_QMARK_($clojure::core::IAssociative, $_[0])
        });

_intern('clojure.core','first', sub {
    my $coll = shift;
    clojure::core::_first(clojure::core::seq($coll))
        });

_intern('clojure.core','rest', sub {
    my $coll = shift;
    clojure::core::_rest(clojure::core::seq($coll)) // $Pajaro::COWList::EMPTY
        });

_intern('clojure.core','next', sub {
    my $coll = shift;
    clojure::core::seq(clojure::core::_rest(clojure::core::seq($coll)))
        });

_intern('clojure.core','seq?',
        sub {
            my $x = shift;
            # nil has first and next (it implements IFirstRest) but (seq? nil) must be false
            if (!defined($x)) { builtin::false }
            else {&clojure::core::satisfies_QMARK_($clojure::core::IFirstRest, $x)}
        });

_intern('clojure.core','seqable?',
        sub {
            my $x = shift;
            &clojure::core::satisfies_QMARK_($clojure::core::ISeqable, $x);
        });

###--- Collection protocols extended to Perl builtin types

_extend_type(_find_type_or_die(''), # the type of nil
             $clojure::core::IFirstRest,
             +{'-first' => sub { undef },
                   '-rest' => sub { undef }},
             $clojure::core::IPeek,
             +{'peek' => sub {undef}},
             $clojure::core::IStack,
             +{'pop'=> sub {undef}},
             $clojure::core::IConj,
             +{'-conj' => sub {
                 shift; # get rid of the nil (collection) that got us here
                 my $ret = clojure::core::list();
                 for my $x (@_) {
                     $ret = clojure::core::_conj($ret, $x);
                 }
                 $ret
               }},
             $clojure::core::IDisj,
             +{'disj'=>sub{undef}},
             $clojure::core::IIndexed,
             +{'nth'=>sub {my $this=shift;
                           my $i=shift;
                           my $else; my $has_else;
                           if (@_) {
                               $else=shift; $has_else=1;
                           }
                           if ($has_else) {
                               $else
                           }
                           else {
                               undef; # nil is special in this way
                           }
               }},
             $clojure::core::ISeqable,
             +{'seq'=>sub { undef }},
             $clojure::core::IAssoc,
             +{'assoc'=>sub{my $x=shift; clojure::core::assoc(clojure::core::hash_map(), @_)}},
             $clojure::core::IDissoc,
             +{'dissoc'=>sub { undef }},
             $clojure::core::IFind,
             +{'find'=>sub { undef }},
             $clojure::core::ILookup,
             +{'contains?'=>sub {builtin::false},
                   'get'=>sub {my $_this=shift;
                               my $_i = shift;
                               my $else = shift;
                               $else}}
    );

_extend_type(type(42), # Long
             $clojure::core::IKeysVals,
             +{'keys'=>sub{die "Notimp"}, 'vals'=>sub{die 'Notimp'}});

_extend_type(type(42.5), # Double
             $clojure::core::IKeysVals,
             +{'keys'=>sub{die "Notimp"}, 'vals'=>sub{die 'Notimp'}});

{
    my $legal_index = sub {my $this = shift;
                           my $k = shift;
			   _anyNumberType($k)
			       && $k >= 0 && $k < (0+@{$this})
			       && (0==($k-int($k)))
                           };
    my $indexed_get = sub{my $this= shift;
                          my $k=shift;
                          my $else;
                          my $has_else;
                          if (@_) {
                              $else=shift;
                              $has_else=1;
                          }
                          if (&$legal_index($this,$k)) {
                              $$this[$k]
                          }
                          elsif ($has_else) {
                              $else
                          }
                          else {
                              die "Index out of range"
                          }
                          };
    _extend_type(type(+[]),
                 $clojure::core::ILookup, +{'contains?'=>$legal_index,
                                                'get'=>sub{
                                                    &{$indexed_get}(@_,undef)
                                            }},
                 $clojure::core::IIndexed, +{'nth'=>$indexed_get},
                 $clojure::core::ISeqable,
                 +{'seq'=>sub {my $this=shift;
                               if (0==@{$this}) {
                                   undef
                               }
                               else {
                                   new Pajaro::IndexedSeq(undef, $this, 0)
                               }}},
                #nope! $clojure::core::ISequential, +{},
                 $clojure::core::ITransientConj, +{'-conj!'=>sub{
                     my $this=shift;
                     my $x=shift;
                     push(@{$this},$x);
                     $this
                                          }},
                 $clojure::core::IFind,
                 +{'find'=>sub { my $this=shift;
                                 my $i = shift;
                                 if (&{$legal_index}($this,$i)) {
                                     my $v=$$this[$i];
                                     new Pajaro::MapEntry($i,$v)
                                 }
                                 else {
                                     undef
                                 }
                   }},

                 $clojure::core::IEquiv, +{'-equiv'=>sub {
                     my $this = shift;
                     my $o = shift;
                     if (!&clojure::core::satisfies_QMARK_($clojure::core::ISequential, $o)) {  builtin::false }
                     elsif (clojure::core::count($this) != clojure::core::count($o)) {
                         builtin::false;
                     }
                     else {
                     for (my $i = 0; $i < clojure::core::count($this); $i++) {
                         if (!clojure::core::equiv($$this[$i], &clojure::core::nth($o, $i))) { return builtin::false }
                     }
                     builtin::true
                 }}});
}

_extend_type(type(+{}),
             $clojure::core::ISeqable, +{'seq'=>sub {my $this = shift;
                                            my @ret;
                                            for my ($k,$v) (%{$this}) {
                                                push(@ret, new Pajaro::MapEntry($k,$v)),
                                            }
                                            clojure::core::list(@ret)
                                }},
             $clojure::core::IKeysVals, +{'keys'=>sub{my $this = shift;
						      if(0==%{$this}) {
							  undef
						      }
						      else {
							  new Pajaro::IndexedSeq(undef, +[CORE::keys(%{$this})], 0)}},
					      'vals'=>sub{my $this = shift;
							  if(0==%{$this}) {
							      undef
							  }
							  else {
							      new Pajaro::IndexedSeq(undef, +[CORE::values(%{$this})], 0)}}},
             $clojure::core::ILookup, +{'contains?'=>sub{my $this= shift;
                                                my $k=shift;
                                                (exists($$this{$k})) ? builtin::true : builtin::false
                               },
                                   'get'=>sub{my $this= shift;
                                              my $k=shift;
                                              my $else=shift;
                                              if (exists($$this{$k})) {$$this{$k}}
                                              else {$else}}},
             $clojure::core::ITransientAssoc, +{'assoc!'=>sub{
                 my $this=shift;
                 my $k= shift;
                 my $v=shift;
                 # Not implemented: multiple k,v pairs
                 $$this{$k}=$v;
                 $this;
                                       }},
             $clojure::core::ITransientDissoc, +{'dissoc!'=>sub {
                 my $this=shift;
                 my $k= shift;
                 delete $$this{$k};
                 $this;
                                        }},
             $clojure::core::IMap, +{},
             $clojure::core::IEquiv, +{'-equiv'=>sub {
                 my $this = shift;
                 my $o = shift;
                 if (!&clojure::core::satisfies_QMARK_($clojure::core::IMap, $o)) { builtin::false }
                 elsif (clojure::core::count($this) != clojure::core::count($o)) { builtin::false }
                 else {
                     for my $k (CORE::keys(%{$this})) {
                         if (!clojure::core::contains_QMARK_($o, $k) ||
			     !clojure::core::equiv($$this{$k}, &clojure::core::get($o, $k))) { return builtin::false }
                     }
                     builtin::true
                 }
                              }}
    );

{
    my $legal_index = sub {my $this = shift;
                           my $k = shift;
                           _anyNumberType($k)
			       && $k >= 0 && $k < length($this)
			       && (0==($k-int($k)))
                           };
    my $indexed_get = sub{my $this= shift;
                          my $k=shift;
                          my $else;
                          my $has_else;
                          if (@_) {
                              $else=shift;$has_else=1;
                          }
                          if (&$legal_index($this,$k)) {
                              substr($this,$k,1)
                          }
                          elsif ($has_else) {
                              $else
                          }
                          else { die "Index out of range" }};
    _extend_type(type('a-string'),
                 $clojure::core::ILookup,
                 +{'contains?'=>$legal_index,
                       'get'=>sub{&{$indexed_get}(@_,undef)}},
                 $clojure::core::IIndexed,
                 +{'nth'=>$indexed_get},
                 $clojure::core::IEmptyable,
                 +{'empty'=>sub{undef}},
                 $clojure::core::ISeqable,
                 +{'seq'=>sub {my $this=shift;
                               if ('' eq $this) { undef; }
                               else {new Pajaro::IndexedSeq(undef, $this, 0)}}});
}

_extend_type(_perl_pkg_name_to_type('UNIVERSAL'),
             $clojure::core::IEmptyable,
             +{'empty'=>sub{undef}},
             $clojure::core::IKeysVals,
             +{'keys'=>sub{undef}, 'vals'=>sub{undef}},
             $clojure::core::ILookup,
             +{'contains?'=>sub{builtin::false},
                   'get'=>sub{my $_this = shift; my $_i = shift;
                              my $else = shift;
                              $else}},
             $clojure::core::IMeta,
             +{'meta'=>sub { undef }});

###--- Collection internal utilities

sub _pr_str_via_perl_array_iteration { # coll must have IPerlArray
    my $coll = shift;
    my $brackets = shift;
    my @s;
    my $sep='';
    push(@s, substr($brackets,0,1));
    for my $x (@{$coll->_perl_array()}) {
        push(@s, $sep);
        push(@s, clojure::core::pr_str($x));
        $sep=' ';
    }
    push(@s, substr($brackets,1,1));
    join('',@s);
}

=pod _seqable_iterator( ISeqable )

Function that returns the collection's next value (in a list), or an
empty list if nothing is left. Remember to call it in list context.
(Technique from Higher Order Perl)

=cut

sub _seqable_iterator { # coll must have ISeqable
    my $coll = shift;
    my $s = clojure::core::seq($coll);
    sub {
        if ($s) {
            my @r = (&clojure::core::_first($s));
            $s = &clojure::core::next($s);
            @r
        }
        else {
            return ();
        }
    }
}

sub _pr_str_via_seqable { # coll must have ISeqable
    my $coll = shift;
    my $brackets = shift;
    my @s;
    my $sep='';
    push(@s, substr($brackets,0,1));
    for (my $s=clojure::core::seq($coll); $s; $s=&clojure::core::next($s)) {
        my $x = &clojure::core::_first($s);
        push(@s, $sep);
        push(@s, clojure::core::pr_str($x));
        $sep=' ';
    }
    push(@s, substr($brackets,1,1));
    join('',@s);
}

sub _equiv_via_seqable { # x coll must have ISeqable
    my $x = shift;
    my $y = shift;
    if (&clojure::core::satisfies_QMARK_($clojure::core::IHash, $x)
        && &clojure::core::satisfies_QMARK_($clojure::core::IHash, $y)
        && &clojure::core::hash($x) != &clojure::core::hash($y)) {
        return builtin::false;
    }
    if (&clojure::core::seqable_QMARK_($y)) {
        my $xs = clojure::core::seq($x);
        my $ys = clojure::core::seq($y);
        for (;;) {
            if (!defined($xs)) {
                return defined($ys) ? builtin::false : builtin::true;
            }
            elsif (!defined($ys)) {
                return builtin::false;
            }
            elsif (! &clojure::core::_equiv(clojure::core::_first($xs), clojure::core::_first($ys))) {
                return builtin::false;
            }
            else {
                $xs = &clojure::core::next($xs);
                $ys = &clojure::core::next($ys);
            }
        }
    }
    else {
        return builtin::false;
    }
}

sub _equiv_via_ICounted {
    my $this = shift;
    my $other = shift;
    if (clojure::core::satisfies_QMARK_($clojure::core::ICounted, $other)) {
        if ($this->count() == clojure::core::count($other)) {
            _equiv_via_seqable($this, $other);
        }
        else {
            builtin::false
        }
    }
    else {
        _equiv_via_seqable($this, $other);
    }
}

sub _equiv_via_lookup { # x coll must have ICount, ISeqable, ILookup
    my $x = shift;
    my $y = shift;
    my $isAssociative = &clojure::core::satisfies_QMARK_($clojure::core::IAssociative, $x);
    my @requiredProtocols = ($clojure::core::IHash, $clojure::core::IEquiv, $clojure::core::ICounted, $clojure::core::ILookup);
    if ($isAssociative) {
        push(@requiredProtocols, $clojure::core::IAssociative);
    }
    for my $requiredProtocol (@requiredProtocols) {
        die "x should have $requiredProtocol" unless
            (&clojure::core::satisfies_QMARK_($requiredProtocol, $x));
        return builtin::false unless
            (&clojure::core::satisfies_QMARK_($requiredProtocol, $y));
    }
    if (&clojure::core::count($x) != &clojure::core::count($y)) {
        return builtin::false;
    }
    if (&clojure::core::hash($x) != &clojure::core::hash($y)) {
        return builtin::false;
    }
    my $xs = clojure::core::seq($x);
    for (;;) {
        if (!defined($xs)) {
            return builtin::true;
        }
        else {
            my $xe = &clojure::core::_first($xs);
            my $xk = $isAssociative ? &clojure::core::key($xe) : $xe;
            return builtin::false unless &clojure::core::contains_QMARK_($y, $xk);
            if ($isAssociative) {
                return builtin::false unless
                    &clojure::core::equiv(&clojure::core::val($xe), &clojure::core::get($y, $xk));
            }
            $xs = &clojure::core::next($xs);
        }
    }
    die "Illegal state";
}

###--- Cons

{
    package Pajaro::Cons;

    our @ISA = qw(Pajaro::AWithMeta);
    # Slot 1 is for metadata
    use constant { HEAD_SLOT => 2 };
    use constant { TAIL_SLOT => 3 };
    use constant { COUNT_SLOT => 4 };

    sub new {
        my $class = shift;
        my $meta = shift;
        my $head = shift;
        my $tail = shift; # may be undef
        my $self = Pajaro::AWithMeta::new_abstract($meta);
        $$self[HEAD_SLOT] = $head;
        $$self[TAIL_SLOT] = $tail;
        $$self[COUNT_SLOT] = clojure::core::satisfies_QMARK_($clojure::core::ICounted, $tail)
            ? 1+clojure::core::count($tail)
            : undef;
        return bless $self, $class;
    }

    # ICloneable of Cons
    sub clone {
        my $this = shift;
        my $ret = +[@{$this}];
        return bless($ret, ref($this));
    }
    # ICount of Cons
    sub count {
        my $this = shift;
        if (!defined($$this[COUNT_SLOT])) {
            my $tail = $$this[TAIL_SLOT];
            $$this[COUNT_SLOT] = 1 + ($tail ? &clojure::core::count($tail) : 0);
        }
        $$this[COUNT_SLOT]
    }
    # IEmptyable of Cons
    sub empty {
        my $this = shift;
        new Pajaro::COWList($this->meta())
    }
    # IEquiv of Cons
    *_equiv = \*Pajaro::_equiv_via_seqable;
    # IHash of Cons
    sub _hash {
        my $this = shift;
        Pajaro::Murmur3::hashOrderedIterator(\&clojure::core::hash, Pajaro::_seqable_iterator($this));
    }
    # IIndexed of Cons
    sub nth {
        my $this = shift;
        my $i = shift;
        my $else;
        my $has_else;
        if (@_) {
            $else= shift; # optional
            $has_else=1;
        }
        my $j = 0;
	if ($i < 0) { die "Out of range" }
        my $hiker = $this;
        while ($j < $i) {
            $hiker = &clojure::core::next($hiker);
            if (!defined($hiker)) {
                if ($has_else) {
                    return $else;
                }
                else {
                    die "Index out of range"
                }
            }
            $j++;
        }
        &clojure::core::first($hiker)
    }
    # INext of Cons
    sub '-next' {
        my $this = shift;
        my $tail = $$this[TAIL_SLOT];
        if ($tail) {
            &clojure::core::seq($tail);
        }
        else {
            undef
        }
    }
    # IPr of Cons
    sub '-pr-str' {
        my $this = shift;
        Pajaro::_pr_str_via_seqable($this, '()');
    }
    # IPrint of Cons
    *_print_str = \*_pr_str;
    # IFirstRest of Cons
    sub '-first' {
        my $this = shift;
        $$this[HEAD_SLOT]
    }
    sub '-rest' {
        my $this = shift;
        $$this[TAIL_SLOT]
    }
    # ISeqable of Cons
    sub seq {
        my $this = shift;
        $this
    }
}

_extend_type(_intern_type('Pajaro.Cons'),
             $clojure::core::ICloneable,
             $clojure::core::ICollection,
             $clojure::core::ICount,
             $clojure::core::IEmptyable,
             $clojure::core::IEquiv,
             $clojure::core::IHash,
             $clojure::core::IIndexed,
             $clojure::core::IList,
             $clojure::core::IMeta,
             $clojure::core::INext,
             $clojure::core::IPr,
             $clojure::core::IPrint,
             $clojure::core::IFirstRest,
             $clojure::core::ISeqable,
             $clojure::core::ISequential,
             $clojure::core::IWithMeta);

_intern('clojure.core','cons',
        sub {
            my $x = shift;
            my $s = shift;
            if (!defined($s)) {
                clojure::core::list($x);
            }
            elsif (clojure::core::seq_QMARK_($s)) {
                new Pajaro::Cons(undef, $x, $s)
            }
            elsif (clojure::core::seqable_QMARK_($s)) {
                new Pajaro::Cons(undef, $x, clojure::core::seq($s))
            }
            else {
                die "Not a collection"
            }
        });

###--- COWList

# Read-only Perl array facade for the array behind a COWList
{
    package Pajaro::TieArray;
    sub TIEARRAY {
        my $classname = shift;
        my $arr = shift;
        die "Need an array not ".ref($arr)." of $arr" unless 'ARRAY' eq ref($arr);
        bless +[$arr], $classname
    }
    sub FETCH {
        my $this = shift;
        my $arr = $$this[0];
        my $n = shift;
        $$arr[$n]
    }
    sub STORE {
        die("STORE is not supported on an IIndexed");
    }
    sub FETCHSIZE {
        my $this = shift;
        my $arr = $$this[0];
        0+@{$arr}
    }
    sub STORESIZE {
        die("STORESIZE is not supported on an IIndexed");
    }
    sub CLEAR {
        die("CLEAR is not supported on an IIndexed");
    }
    sub UNTIE {
    }
    sub DESTROY {
    }
}

# This "list" is backed by a Perl array.
{
    package Pajaro::COWList;
    our @ISA =qw(Pajaro::AWithMeta);
    # Slot 1 is for metadata
    use constant { STUFF_SLOT => 2 };
    sub new {
        my $class = shift;
        my $meta = shift;
        my @xs = @_;
        my $self = Pajaro::AWithMeta::new_abstract($meta);
        $$self[STUFF_SLOT] = +[@xs];
        return bless $self, $class;
    }
    # ICloneable of COWList
    sub clone {
        my $this = shift;
        my $ret = +[@$this[0.. STUFF_SLOT-1], +[@{$$this[STUFF_SLOT]}]];
        bless($ret, ref($this))
    }
    # IConj of COWList
    sub '-conj' {
        # any arity
        my $this = shift;
        my @xs = @_;
        my $ret = $this->clone();
        unshift(@{$$ret[STUFF_SLOT]}, CORE::reverse(@xs));
        $ret->_clear_hash();
        $ret
    }
    # ICount of COWList
    sub count {
        my $this = shift;
        0+@{$$this[STUFF_SLOT]}
    }
    # IDrop of COWList
    sub '-drop' {
        my $this = shift;
        my $n = shift;
        if (0==$n) {
            $this
        }
        elsif ((0 < $n)
               && ($n < @{$$this[STUFF_SLOT]})) {
            # Cannot delegate to IndexedSeq; List is not IIndexed
            my $ret = $this->clone();
	    $ret->_clear_hash();
            splice(@{$$ret[STUFF_SLOT]}, 0, $n, ());
            $ret
        }
        else {
            undef
        }
    }
    # IEmptyable of COWList
    our $EMPTY = new Pajaro::COWList(undef);
    sub empty {
        my $this = shift;
        new Pajaro::COWList($this->meta())
    }
    # IEquiv of COWList
    *_equiv = \*Pajaro::_equiv_via_seqable;
    # IHash of COWList
    sub _hash {
        my $this = shift;
        Pajaro::Murmur3::hashOrdered(\&clojure::core::hash,
                                   $$this[STUFF_SLOT]);
    }
    # IIndexed of COWList
    sub nth {
        my $this = shift;
        my $i = shift;
        my $else;
        my $has_else;
        if (@_) {
            $else= shift;
            $has_else=1;
        }
	if ($i < 0) { die "Out of range" }
        my $a = $$this[STUFF_SLOT];
        if ($i >= 0 && $i < @$a) {
            $$a[$i]
        }
        elsif ($has_else) {
            $else
        }
        else {
            die 'Index out of range'
        }
    }
    # INext of COWList
    sub '-next' {
        my $this = shift;
        &'-drop'($this, 1)
    }
    # IPeek of COWList
    *peek = \&_first;
    # IPerlArray of COWList
    sub _perl_array {
        my $this=shift;
        # Don't expose our backing array. Return a read-only facade
        my @a;
        tie(@a, 'Pajaro::TieArray', $$this[STUFF_SLOT]);
        \@a;
    }
    # IPr of COWList
    sub '-pr-str' {
        my $this = shift;
        Pajaro::_pr_str_via_perl_array_iteration($this, '()');
    }
    # IPrint of COWList
    *_print_str = \*_pr_str;
    # IReversible of COWList
    sub '-rseq' {
        my $this = shift;
        if (0 == @{$$this[STUFF_SLOT]}) {
            undef
        }
        else {
            new Pajaro::COWList($$this[Pajaro::AMeta::AMETA_SLOT],
                              CORE::reverse(@{$$this[STUFF_SLOT]}))
        }
    }
    # IFirstRest of COWList
    sub '-first' {
        my $this = shift;
        if (0 == @{$$this[STUFF_SLOT]}) {
            undef
        }
        else {
            $$this[STUFF_SLOT][0];
        }
    }
    sub '-rest' {
        my $this = shift;
        $this->_next() // $this->empty()
    }
    # ISeqable of COWList
    sub seq {
        my $this = shift;
        if (0 == @{$$this[STUFF_SLOT]}) {
            undef
        }
        else {
            $this
        }
    }
    # IStack of COWList
    sub pop {
        my $this = shift;
        die "Can't pop empty list" if (0==@{$$this[STUFF_SLOT]});
        $this->_rest()
    }
}

_extend_type(_intern_type('Pajaro.COWList'),
             $clojure::core::ICloneable,
             $clojure::core::ICollection,
             $clojure::core::IConj,
             $clojure::core::ICount,
             $clojure::core::ICounted,
             $clojure::core::IDrop,
             $clojure::core::IEmptyable,
             $clojure::core::IEquiv,
             $clojure::core::IHash,
             $clojure::core::IIndexed,
             $clojure::core::IList,
             $clojure::core::IMeta,
             $clojure::core::INext,
             $clojure::core::IPeek,
             $clojure::core::IPerlArray,
             $clojure::core::IPr,
             $clojure::core::IPrint,
             $clojure::core::IReversible,
             $clojure::core::IFirstRest,
             $clojure::core::ISequential,
             $clojure::core::ISeqable,
             $clojure::core::IStack,
             $clojure::core::IWithMeta);

_intern('clojure.core','list',sub{
    new Pajaro::COWList(undef, @_)
        });

_intern('clojure.core','list?', sub {
    my $kw = shift;
    my $t = clojure::core::type($kw);
    return clojure::core::boolean($t && ('Pajaro.COWList' eq $t->name()));
     });

###--- Indexed things

# A read-only Perl array facade for an IIndexed collection
{
    package Pajaro::TieIndexed;
    sub TIEARRAY {
        my $classname = shift;
        my $indexed = shift;
        bless(+[$indexed], $classname)
    }
    sub FETCH {
        my $this = shift;
        my $indexed = $$this[0];
        my $n = shift;
        $indexed->nth($n)
    }
    sub STORE {
        die("STORE is not supported on an IIndexed")
    }
    sub FETCHSIZE {
        my $this = shift;
        my $indexed = $$this[0];
        $indexed->count()
    }
    sub STORESIZE {
        die("STORESIZE is not supported on an IIndexed")
    }
    sub CLEAR {
        die("CLEAR is not supported on an IIndexed")
    }
    sub UNTIE {
    }
    sub DESTROY {
    }
}

# IndexedSeq - An offset view of an IIndexed collection
{
    package Pajaro::IndexedSeq;

    our @ISA=qw(Pajaro::AWithMeta);

    # Slot 1 is for metadata
    use constant { COLL_SLOT => 2 };
    use constant { INDEX_SLOT => 3 };

    sub new {
        my $class = shift;
        my $meta = shift;
        my $coll = shift;
        my $index = shift;
        my $self = Pajaro::AWithMeta::new_abstract($meta);
        $$self[COLL_SLOT] = $coll;
        $$self[INDEX_SLOT] = $index;
        bless $self, $class
    }

    # ICloneable of IndexedSeq
    sub clone {
        my $this = shift;
        my $ret = +[@{$this}];
        bless($ret, ref($this))
    }
    # IConj of IndexedSeq
    sub '-conj' {
        # any arity
        my $this = shift;
        my @xs = @_;
        for my $x (@xs) {
            $this = new Pajaro::Cons($$this[Pajaro::AMeta::AMETA_SLOT], $x, $this);
        }
        $this
    }
    # ICount of IndexedSeq
    sub count {
        my $this = shift;
        clojure::core::count($$this[COLL_SLOT]) - $$this[INDEX_SLOT]
    }
    # IDrop of IndexedSeq
    sub '-drop' {
        my $this = shift;
        my $n = shift;
        if (0==$n) {
            $this
        }
        elsif ((0 < $n)
                 && ($n+$$this[INDEX_SLOT]<clojure::core::count($$this[COLL_SLOT]))) {
            my $ret = $this->clone();
	    $ret->_clear_hash();
            $$ret[INDEX_SLOT] += $n;
            $ret
        }
        else {
            undef
        }
    }
    # IEmptyable of IndexedSeq
    sub empty {
        my $this = shift;
        new Pajaro::COWList($this->meta())
    }
    # IEquiv of IndexedSeq
    *_equiv = \*Pajaro::_equiv_via_seqable;
    # IHash of IndexedSeq
    sub _hash {
        my $this = shift;
        Pajaro::Murmur3::hashOrdered(\&clojure::core::hash, $this->_perl_array());
    }
    # IIndexed of IndexedSeq
    sub nth {
        my $this = shift;
        my $i = shift;
        # there might remain an 'else' value in @_. Pass it along
        clojure::core::nth($$this[COLL_SLOT], $i + $$this[INDEX_SLOT], @_)
    }
    # INext of IndexedSeq
    sub '-next' {
        my $this = shift;
        &'-drop'($this, 1)
    }
    # IPerlArray of IndexedSeq
    sub _perl_array {
        my $this=shift;
        my @a;
        tie(@a, 'Pajaro::TieIndexed', $this);
        \@a
    }
    # IPr of IndexedSeq
    sub '-pr-str' {
        my $this = shift;
        Pajaro::_pr_str_via_perl_array_iteration($this, '()')
    }
    # IPrint of IndexedSeq
    *_print_str = \*_pr_str;
    # IReversible of IndexedSeq
    sub '-rseq' {
        my $this = shift;
        if (0 == $this->count()) {
            undef
        }
        else {
            new Pajaro::ReverseIndexedSeq($this)
        }
    }
    # IFirstRest of IndexedSeq
    sub '-first' {
        my $this = shift;
        if (0 == $this->count()) {
            undef
        }
        else {
            $this->nth(0)
        }
    }
    sub '-rest' {
        my $this = shift;
        $this->_next() // $this->empty()
    }
    # ISeqable of IndexedSeq
    sub seq {
        my $this = shift;
        if (0 == $this->count()) {
            undef
        }
        else {
            $this
        }
    }
    # ISequential of IndexedSeq
}

_extend_type(_intern_type('Pajaro.IndexedSeq'),
             $clojure::core::ICloneable,
             $clojure::core::IConj,
             $clojure::core::ICount,
             $clojure::core::ICounted,
             $clojure::core::IDrop,
             $clojure::core::IEmptyable,
             $clojure::core::IEquiv,
             $clojure::core::IHash,
             $clojure::core::IIndexed,
             $clojure::core::IMeta,
             $clojure::core::INext,
             $clojure::core::IPerlArray,
             $clojure::core::IPr,
             $clojure::core::IPrint,
             $clojure::core::IReversible,
             $clojure::core::IFirstRest,
             $clojure::core::ISeqable,
             $clojure::core::ISequential,
             $clojure::core::IWithMeta);

# AVector - Common foundations for TransientVector and COWVector
sub _compare_vectors {
    my $this = shift;
    my $other = shift;
    if (!defined($other)) { 1 }
    elsif (!Scalar::Util::blessed($other)
           || !($other->isa("Pajaro::AVector") || $other->isa("Pajaro::MapEntry"))) {
        die ("Vector is comparable only with Vector or MapEntry: "
            . _type_name($this) . ' vs ' . _type_name($other))

    }
    else {
        my $c = $this->count;
        my $oc = $other->count();
        if ($c < $oc) {
            return -1
        }
        elsif ($c > $oc) {
            return 1
        }
        else {
            for (my $i = 0; $i < $c; $i++) {
                my $x = $this->nth($i);
                my $ox = $other->nth($i);
                my $vs = &clojure::core::compare($x, $ox);
                if ($vs != 0) {
                    return $vs;
                }
            }
        }
        0
    }
}

{
    package Pajaro::AVector;
    our @ISA =qw(Pajaro::AWithMeta);
    # Slot 1 is for metadata
    use constant { STUFF_SLOT => 2 };

    sub new_abstract {
        my $meta = shift;
        my @xs = @_;
        my $self = Pajaro::AWithMeta::new_abstract($meta);
        $$self[STUFF_SLOT] = +[@xs];
        $self;
    }
    sub new_alias {
        my $meta = shift;
        my $arr = shift;
        my $self = Pajaro::AWithMeta::new_abstract($meta);
        $$self[STUFF_SLOT] = $arr;
        $self;
    }
    # ICloneable of AVector
    sub clone {
        my $this = shift;
        my $ret = +[@$this[0.. STUFF_SLOT-1], +[@{$$this[STUFF_SLOT]}]];
        bless($ret, ref($this))
    }
    # IComparable of AVector
    sub compare {
        Pajaro::_compare_vectors(@_)
    }
    # ICount of AVector
    sub count {
        my $this = shift;
        0+@{$$this[STUFF_SLOT]}
    }
    # IFn of AVector
    sub '-code' {
        my $this = shift;
        sub {
            my $i = shift;
            # there might remain an 'else' value in @_. Pass it along
            nth($this, $i, @_);
        }
    }
    # IEquiv of AVector
    *_equiv = \*Pajaro::_equiv_via_ICounted;
    # IFind of AVector
    sub 'find' {
        my $this = shift;
        my $i = shift;
        if (clojure::core::contains_QMARK_($this,$i)) {
            new Pajaro::MapEntry($i, clojure::core::nth($this, $i))
        }
        else {
            undef
        }
    }
    # IHash of AVector
    sub _hash {
        my $this = shift;
        Pajaro::Murmur3::hashOrdered(\&clojure::core::hash,
                                   $$this[STUFF_SLOT]);
    }
    # IIndexed of AVector
    sub nth {
        my $this = shift;
        my $i = shift;
        my $not_found;
        my $has_else;
        if (@_) {
            $not_found= shift; # optional
            $has_else=1;
        }
        if (!Pajaro::_anyNumberType($i)) { die "Key must be integer" }
        my $a = $$this[STUFF_SLOT];
	my $limit = @$a;
        if ($i >= 0 && $i < $limit) {
            $$a[$i]
        }
        elsif ($has_else) {
            $not_found
        }
        else {
            die "Index $i out of range [0,$limit) and no else provided in nth\n"
        }
    }
    # ILookup of AVector
    sub 'contains?' {
        my $this = shift;
        my $i = shift;
        if (Pajaro::_anyNumberType($i)) {
            my $a = $$this[STUFF_SLOT];
            ($i >= 0 && $i < @$a) ? builtin::true : builtin::false;
        }
        else {
            builtin::false
        }
    }
    sub 'get' {
        my $this=shift;
        my $i = shift;
        my $else = shift;
	if (Pajaro::_anyNumberType($i)) {
	    $this->nth($i,$else)
	}
	else {
	    $else
	}
    }
    # IPeek of AVector
    sub peek {
        my $this = shift;
        my $idx = @{$$this[STUFF_SLOT]} - 1;
        if ($idx >= 0) {
            $$this[STUFF_SLOT][$idx]
        }
        else {
            undef
        }
    }
    # IPerlArray of AVector
    sub _perl_array {
        my $this=shift;
        # Don't expose our backing array. Return a read-only facade
        my @a;
        tie(@a, 'Pajaro::TieIndexed', $this);
        \@a;
    }
    # IPr of AVector
    sub '-pr-str' {
        my $this = shift;
        Pajaro::_pr_str_via_perl_array_iteration($this, '[]');
    }
    *_print_str = \*_pr_str; # IPrint of AVector
    # IReversible of AVector
    sub '-rseq' {
        my $this = shift;
        if (0 == @{$$this[STUFF_SLOT]}) {
            undef
        }
        else {
            new Pajaro::COWList($$this[Pajaro::AMeta::AMETA_SLOT],
                              CORE::reverse(@{$$this[STUFF_SLOT]}))
        }
    }
    # ISeqable of AVector
    sub seq {
        my $this = shift;
        if (0 == @{$$this[STUFF_SLOT]}) {
            undef
        }
        else {
            new Pajaro::IndexedSeq(undef, $this, 0)
        }
    }
    # utility
    sub _assocInPlace {
        my $this = shift;
        my @kvs = @_;
        if (1 == @kvs % 2) {
            die "Expected whole k,v pairs"
        }
        my $ret = $this;#transient does not ->clone();
        for my ($k,$v) (@kvs) {
            if ($k >= 0 && $k <= @{$$ret[STUFF_SLOT]}) {
                $$ret[STUFF_SLOT][$k] = $v;
            }
            else {
                die "Index out of bounds $k"
            }
        }
        $ret->_clear_hash();
        $ret;
    }
    sub _conjInPlace {
        # any arity
        my $this = shift;
        my @xs = @_;
        my $ret = $this; # transient does not ->clone();
        push(@{$$ret[STUFF_SLOT]}, @xs);
        $ret->_clear_hash();
        $ret
    }
    sub _popInPlace {
        my $this = shift;
        if (0 < @{$$this[STUFF_SLOT]}) {
            my $ret = $this; # transient does not ->clone();
            CORE::pop @{$$ret[STUFF_SLOT]};
            $ret->_clear_hash();
            $ret
        }
        else {
            die "Can't pop empty vector"
        }
    }
}

# TransientVector - The vector is backed by a Perl array.
{
    package Pajaro::TransientVector;
    our @ISA =qw(Pajaro::AVector);

    sub new {
        my $class = shift;
        my $self = Pajaro::AVector::new_abstract(@_);
        bless $self, $class;
    }
    sub new_alias {
        my $class = shift;
        my $self = Pajaro::AVector::new_alias(@_);
        bless $self, $class;
    }
    # ICloneable - from AVector
    # IComparable - from AVector
    # ICount - from AVector
    # IEmptyable of TransientVector
    sub empty { new Pajaro::TransientVector() }
    # IEquiv - from AVector
    # IFind - from AVector
    # IFn - from AVector
    # IHash - from AVector
    # IIndexed - from AVector
    # ILookup - from AVector
    # IPeek - from AVector
    # IPerlArray - from AVector
    # IPr - from AVector
    # IPrint - from AVector
    # IReversible - from AVector
    # ISeqable - from AVector
    # ITransientAssoc of TransientVector
    sub 'assoc!' {
        my $this = shift;
        my @kvs = @_;
        # assoc! accepts an odd number of parameters and assumes the missing final one is nil.
        if (1 == @kvs % 2) {
            push(@kvs, undef);
        }
        $this->_assocInPlace(@kvs);
    }
    # ITransientCollection of TransientVector
    sub persistent_BANG_ {
        my $this = shift;
        my $ret = Pajaro::COWVector->new($$this[Pajaro::AMeta::AMETA_SLOT],
                                       @{$$this[Pajaro::AVector::STUFF_SLOT]});
        bless $this, 'Pajaro::Vacant';
        return $ret;
    }
    # ITransientConj of TransientVector
    *_conj_BANG_ = \&Pajaro::AVector::_conjInPlace;
    # ITransientStack of TransientVector
    *pop_BANG_ = \&Pajaro::AVector::_popInPlace;
    use overload '&{}' => '_code', 'fallback' => 1;
}

# Note: Transient vector is Not IAssociative; persistent vector is
_extend_type(_intern_type('Pajaro.TransientVector'),
             $clojure::core::ICollection,
             $clojure::core::ICloneable,
             $clojure::core::ICount,
             $clojure::core::ICounted,
             $clojure::core::IEmptyable,
             $clojure::core::IEquiv,
             $clojure::core::IFn,
             $clojure::core::IFind,
             $clojure::core::IHash,
             $clojure::core::IIndexed,
             $clojure::core::ILookup,
             $clojure::core::IMeta,
             $clojure::core::IPerlArray,
             $clojure::core::IPr,
             $clojure::core::IPrint,
             $clojure::core::IReversible,
             $clojure::core::ISeqable,
             $clojure::core::ISequential,
             $clojure::core::ITransientAssoc,
             $clojure::core::ITransientCollection,
             $clojure::core::ITransientConj,
             $clojure::core::ITransientStack,
             $clojure::core::IVector,
             $clojure::core::IWithMeta);

# COWVector - The vector is backed by a Perl array.
{
    package Pajaro::COWVector;
    our @ISA =qw(Pajaro::AVector);

    sub new {
        my $class = shift;
        my $self = Pajaro::AVector::new_abstract(@_);
        bless $self, $class
    }
    sub new_alias {
        my $class = shift;
        my $self = Pajaro::AVector::new_alias(@_);
        bless $self, $class;
    }
    # IAssoc
    sub assoc {
        my $this = shift;
        my @kvs = @_;
        my $ret = $this->clone();
        $ret->_assocInPlace(@kvs)
    }
    # ICloneable - from AVector
    # IComparable - from AVector
    # IConj of COWVector
    sub '-conj' {
        # any arity
        my $this = shift;
        my @xs = @_;
        my $ret = $this->clone();
        $ret->_conjInPlace(@xs)
    }
    # ICount - from AVector
    # IEditableCollection of COWVector
    sub transient {
        my $this = shift;
        new Pajaro::TransientVector($$this[Pajaro::AMeta::AMETA_SLOT],
                                  @{$$this[Pajaro::AVector::STUFF_SLOT]})
    }
    # IEmptyable of COWVector
    our $EMPTY = new Pajaro::COWVector(); # used by Transpiler
    sub empty {
        my $this = shift;
        new Pajaro::COWVector($this->meta())
    }
    # IEquiv - from AVector
    # IFind - from AVector
    # IFn - from AVector
    # IHash - from AVector
    # IIndexed - from AVector
    # ILookup - from AVector
    # IPeek - from AVector
    # IPerlArray - from AVector
    # IPr - from AVector
    # IPrint - from AVector
    # IReversible - from AVector
    # ISeqable - from AVector
    # IStack - from AVector
    sub pop {
        my $this = shift;
        my $ret = $this->clone();
        $ret->_popInPlace();
    }
    use overload '&{}' => '_code', 'fallback' => 1;
}

_intern('clojure.core','vector?',sub {
    ('Pajaro::COWVector' eq ref($_[0]))
        || ('Pajaro::MapEntry' eq ref($_[0])) });

_extend_type(_intern_type('Pajaro.COWVector'),
             $clojure::core::IAssoc,
             $clojure::core::IAssociative,
             $clojure::core::ICloneable,
             $clojure::core::ICollection,
             $clojure::core::IComparable,
             $clojure::core::IConj,
             $clojure::core::ICount,
             $clojure::core::ICounted,
             $clojure::core::IEditableCollection,
             $clojure::core::IEmptyable,
             $clojure::core::IEquiv,
             $clojure::core::IFind,
             $clojure::core::IFn,
             $clojure::core::IHash,
             $clojure::core::IIndexed,
             $clojure::core::ILookup,
             $clojure::core::IMeta,
             $clojure::core::IPeek,
             $clojure::core::IPerlArray,
             $clojure::core::IPr,
             $clojure::core::IPrint,
             $clojure::core::IReversible,
             $clojure::core::ISequential,
             $clojure::core::ISeqable,
             $clojure::core::IStack,
             $clojure::core::IVector,
             $clojure::core::IWithMeta);

_intern('clojure.core','vector',sub{
    new Pajaro::COWVector(undef, @_)
        });

_intern('clojure.core', 'conj', sub {
    if (0==@_) { return clojure::core::vector(); }
    elsif (1==@_) { return $_[0]; }
    elsif (clojure::core::satisfies_QMARK_($clojure::core::IConj, $_[0])) {
        goto &clojure::core::_conj;
    }
    elsif (clojure::core::satisfies_QMARK_($clojure::core::IFirstRest, $_[0])) {
        my $ret = shift;
        for my $x (@_) {
            $ret = clojure::core::cons($x, $ret);
        }
        $ret
    }
    else {
        die "Not conjable"
    }
        });

_intern('clojure.core', 'conj!', sub {
    if (0==@_) { return clojure::core::transient(clojure::core::vector()); }
    elsif (1==@_) { return $_[0]; }
    else {
        goto &clojure::core::_conj_BANG_;
    }
        });

_intern('clojure.core','subvec',sub {
    my $v = shift;
    die'Not a vector' unless clojure::core::vector_QMARK_($v);
    my $vstuf = $$v[Pajaro::AVector::STUFF_SLOT];
    my $start = shift;
    my $end;
    if(@_) {
        $end= shift;
        die 'end must be a number' if (!defined($end));
    }
    $end = $end // (0+@{$vstuf});
    die 'vector required' if (!defined($v));
    die 'start must not be negative' if(!defined($start) || $start<0);
    die 'end must not be less than start' if (!defined($end) || $end < $start);
    die 'end must not be beyond vector' if ($end > (0+@{$vstuf}));
    my $endIncl = $end - 1;
    my @content = @{$vstuf}[$start..$endIncl];
    &clojure::core::vector(@content);
        });

###--- Associative things

{
    package Pajaro::MapEntry;
    our @ISA = qw(Pajaro::AHash);
    # important: array slice [KEY_SLOT,VALUE_SLOT] for interoperability with Vector
    use constant { KEY_SLOT => 1 };
    use constant { VALUE_SLOT => 2 };

    sub new {
        my $class = shift;
        my $k = shift;
        my $v = shift;
        my $self = Pajaro::AHash::new_abstract();
        $$self[KEY_SLOT] = $k;
        $$self[VALUE_SLOT] = $v;
        bless $self, $class;
    }
    # IMapEntry of MapEntry
    sub key {
        my $this = shift;
        $$this[KEY_SLOT];
    }
    sub val {
        my $this = shift;
        $$this[VALUE_SLOT];
    }
    # ICollection of MapEntry
    # IComparable of MapEntry
    sub compare {
        Pajaro::_compare_vectors(@_)
    }
    # ICount of MapEntry
    sub count { 2 };
    # ICounted of MapEntry
    # IEquiv of MapEntry
    *_equiv = \*Pajaro::_equiv_via_ICounted;
    # IHash of MapEntry
    sub _hash {
        my $this = shift;
        my @arrayToHash = @$this[KEY_SLOT,VALUE_SLOT];
        Pajaro::Murmur3::hashOrdered(\&clojure::core::hash, \@arrayToHash);
    }
    # IIndexed of MapEntry
    sub nth {
        my $this = shift;
        my $n = shift;
        my $notfound;
        my $has_else;
        if (@_) {
            $notfound= shift;
            $has_else=1;
        }
        if ($n == 0) { $$this[KEY_SLOT] }
        elsif ($n == 1) { $$this[VALUE_SLOT] }
        elsif ($has_else) { $notfound }
        else { die('Index out of range') }
    }
    # ILookup of MapEntry
    sub 'contains?' {
        my $this = shift;
        my $i = shift;
        Pajaro::_anyNumberType($i) && (($i == 0) || ($i == 1))
    }
    sub 'get' {
        my $this=shift;
        my $i=shift;
        my $else=shift;
        $this->nth($i,$else)
    }
    # IPerlArray of MapEntry
    sub _perl_array {
        my $this=shift;
        +[$$this[KEY_SLOT], $$this[VALUE_SLOT]];
    }
    # IPr of MapEntry
    sub '-pr-str' {
        my $this = shift;
        Pajaro::_pr_str_via_perl_array_iteration($this, '[]');
    }
    # IPrint of MapEntry
    *_print_str = \*_pr_str;
    # ISequential of MapEntry
    # ISeqable of MapEntry
    sub seq {
        my $this = shift;
        new Pajaro::COWList(undef, $$this[KEY_SLOT], $$this[VALUE_SLOT]);
    }
}

_extend_type(_intern_type('Pajaro.MapEntry'),
             $clojure::core::ICount,
             $clojure::core::IComparable,
             $clojure::core::ICounted,
             $clojure::core::IEquiv,
             $clojure::core::IHash,
             $clojure::core::IIndexed,
             $clojure::core::ILookup,
             $clojure::core::IMapEntry,
             $clojure::core::IPerlArray,
             $clojure::core::IPr,
             $clojure::core::IPrint,
             $clojure::core::ISeqable,
    );

_intern('clojure.core','map-entry?',sub{ 'Pajaro::MapEntry' eq ref($_[0])});
_intern('clojure.core','map?',
	sub{ clojure::core::satisfies_QMARK_($clojure::core::IMap, $_[0])});

=pod Pajaro::COWMap

This map is backed by a three-level structure. A Perl hash
maps a Clojure hashcode to a Perl array of Clojure map entries,
which in turn consist of Clojure map key and value.

=cut
{
    package Pajaro::MapEntrySeq;
    our @ISA = qw(Pajaro::AWithMeta);
    # Slot 1 is for metadata
    # Bucket & offset correspond to 'first'
    use constant { STUFF_SLOT => 2 }; # the whole Perl map
    use constant { BUCKET_SLOT => 3 }; # bucket of 'first'
    use constant { OFFSET_SLOT => 4 }; # offset of 'first' in its bucket
    use constant { MOREKEYS_SLOT => 5 }; # future bucket keys
    use constant { POSTPROCESS_SLOT => 6}; # fn of MapEntry
    # A meta-sequence of the per-bucket sequences
    sub new {
        my $class = shift;
        my $meta = shift;
        my $amap_stuff = shift;
        my $bucket = shift;
        my $offset = shift;
        my $morekeys = shift;
        my $post = shift;
        my $self = Pajaro::AWithMeta::new_abstract($meta);
        $$self[STUFF_SLOT] = $amap_stuff;
        $$self[BUCKET_SLOT] = $bucket;
        $$self[OFFSET_SLOT] = $offset;
        $$self[MOREKEYS_SLOT] = $morekeys;
        $$self[POSTPROCESS_SLOT] = $post;
        bless $self, $class;
    }
    sub set_post_process_BANG_ {
        my $this = shift;
        my $post = shift;
        $$this[POSTPROCESS_SLOT] = $post;
    }
    # ICloneable of MapEntrySeq
    sub clone {
        my $this = shift;
        my $ret = +[@$this[0.. STUFF_SLOT-1],
                    $$this[STUFF_SLOT],
                    $$this[BUCKET_SLOT],
                    $$this[OFFSET_SLOT],
                    +[@{$$this[MOREKEYS_SLOT]}],
                    $$this[POSTPROCESS_SLOT]];
        bless($ret, ref($this));
    }
    # IHash of MapEntrySeq
    sub _hash {
        my $this = shift;
        Pajaro::Murmur3::hashOrderedIterator(\&clojure::core::hash, Pajaro::_seqable_iterator($this));
    }
    # INext of MapEntrySeq
    sub '-next' {
        my $this = shift;
        my $tail = $this->_rest();
        if ($tail) {
            &clojure::core::seq($tail); # i.e., nil if no content
        }
        else {
            undef
        }
    }
    # ICount of MapEntrySeq
    sub 'count' {
        my $this = shift;
        if ($$this[BUCKET_SLOT]) {
            1 + clojure::core::count($this->_next())
        }
        else {
            0
        }
    }
    # IFirstRest of MapEntrySeq
    sub '-first' {
        my $this = shift;
        if ($$this[BUCKET_SLOT]) {
            my $e = $$this[BUCKET_SLOT][$$this[OFFSET_SLOT]];
            my $f = $$this[POSTPROCESS_SLOT];
            if ($f) {
                &{$f}($e)
            }
            else {
                $e
            }
        }
        else {
            undef
        }
    }
    sub '-rest' {
        my $this = shift;
        if ($$this[BUCKET_SLOT]) {
            my $ret = $this->clone();
	    $ret->_clear_hash();
            $$ret[OFFSET_SLOT]++;
            if ($$ret[OFFSET_SLOT] == @{$$ret[BUCKET_SLOT]}) {
                $$ret[OFFSET_SLOT]=0;
                my $h = shift(@{$$ret[MOREKEYS_SLOT]});
                if (defined($h)) {
                    $$ret[BUCKET_SLOT] = $$ret[STUFF_SLOT]{$h};
                }
                else {
                    undef $$ret[BUCKET_SLOT];
                }
            }
            $ret
        }
        else {
            $this
        }
    }
    # IPr of MapEntrySeq
    sub '-pr-str' {
        my $this = shift;
	Pajaro::_pr_str_via_seqable($this, '()');
    }
    # IPrint of MapEntrySeq
    *_print_str = \*_pr_str;
    # ISeqable of MapEntrySeq
    sub seq {
        my $this = shift;
        if ($$this[BUCKET_SLOT]) {
            $this
        }
        else {
            undef
        }
    }
}

_extend_type(_intern_type('Pajaro.MapEntrySeq'),
             $clojure::core::ICloneable,
             $clojure::core::ICount,
             $clojure::core::IHash,
             $clojure::core::IMeta,
             $clojure::core::INext,
	     $clojure::core::IPr,
	     $clojure::core::IPrint,
             $clojure::core::IFirstRest,
             $clojure::core::ISeqable,
             $clojure::core::ISequential,
             $clojure::core::IWithMeta);

{
    package Pajaro::AAssociative;
    our @ISA = qw(Pajaro::AWithMeta);
    # Slot 1 is for metadata
    use constant { STUFF_SLOT => 2 };
    use constant { COUNT_SLOT => 3 };
    sub new_abstract_entries {
        my $meta = shift;
        my @entries = @_;
        my $self = Pajaro::AWithMeta::new_abstract($meta);
        $$self[STUFF_SLOT] = +{};
        $$self[COUNT_SLOT] = 0;
        _conjEntriesInPlace($self, @entries);
    }
    # ICloneable of AAssociative
    sub clone {
        my $this = shift;
        my $ret = +[@$this[0.. STUFF_SLOT-1],
                    +{},
                    $$this[COUNT_SLOT]];
        # deep copy hash buckets
        for my $h (CORE::keys(%{$$this[STUFF_SLOT]})) {
            $$ret[STUFF_SLOT]{$h} = +[@{$$this[STUFF_SLOT]{$h}}]
        }
        bless($ret, ref($this));
    }
    # ICount of AAssociative
    sub count {
        my $this = shift;
        $$this[COUNT_SLOT]
    }
    # IEquiv of AAssociative
    *_equiv = \&Pajaro::_equiv_via_lookup;
    # IFn of AAssociative
    sub '-code' {
        my $this = shift;
        sub {
            my $k = shift;
            my $not_found = shift; # optional
            &clojure::core::get($this, $k, $not_found);
        }
    }
    # IHash of AAssociative
    sub _hash {
        my $this = shift;
        Pajaro::Murmur3::hashUnorderedIterator
            (\&clojure::core::hash, Pajaro::_seqable_iterator($this));
    }
    # ILookup (contains?, but not get)
    sub 'contains?' {
        my $this = shift;
        my $k = shift;
        my ($b, $j) = _findEntry($this, $k);
        defined($j) ? builtin::true : builtin::false;
    }

    # utilities
    sub _findEntry { # ret (bucket/array ref, offset within bucket) or undef
        # b undef if nothing by the hashkey
        # j undef if hash bucket exists but the key isn't in it
        my $this = shift;
        my $k = shift;
        my $h = &clojure::core::hash($k);
        if (exists($$this[STUFF_SLOT]{$h})) {
            my $b = $$this[STUFF_SLOT]{$h};
            my @p = @{$b};
            for (my $j = 0; $j < @p; $j++) {
                my $pk = $p[$j]->key(); #[Pajaro::MapEntry::KEY_SLOT];
                if (&clojure::core::equiv($k, $pk)) {
                    return ($b, $j);
                }
            }
            return ($b, undef);
        }
        undef
    }
    sub _assocOneEntryInPlace {
        my $this = shift;
        my $e = shift;
        my $k = $e->key();
        Pajaro::AHash::_clear_hash($this);
        my ($b, $j) = _findEntry($this, $k);
        if (defined($b)) {
            if (defined($j)) {
                $$b[$j] = $e;
            }
            else {
                push(@{$b}, $e);
                ++$$this[COUNT_SLOT];
            }
        }
        else {
            $$this[STUFF_SLOT]{&clojure::core::hash($k)} = +[$e];
            ++$$this[COUNT_SLOT];
        }
        $this
    }
    sub _assocInPlace {
        my $this = shift;
        my @kvs = @_;
        if (1 == @kvs % 2) {
            die "Expected whole k,v pairs"
        }
        for (my $i = 0; $i < @kvs; $i += 2) {
            my $k = $kvs[$i];
            my $v = $kvs[$i+1];
            my $e = new Pajaro::MapEntry($k, $v);
            $this = _assocOneEntryInPlace($this, $e);
        }
        $this
    }
    sub _conjOneEntryInPlace {
        my $this = shift;
        my $e = shift;
        die "undefined MapEntry" unless defined($e);
        # MapEntry does not carry metadata.
        # If given a vector, transfer its contents to a MapEntry.
        if (ref($e) ne 'Pajaro::MapEntry') {
            $e = new Pajaro::MapEntry($e->nth(0), $e->nth(1));
        }
        _assocOneEntryInPlace($this, $e)
    }
    sub _conjEntriesInPlace {
        my $this = shift;
        my @ee = @_;
        for my $e (@ee) {
            # We're sometimes called before this is blessed...
            if (Scalar::Util::blessed($this) && $this->isa("Pajaro::AMap") && ref($e) && Scalar::Util::blessed($e) && $e->isa("Pajaro::AMap")) {
                #(conj map map) is a bit like merge... but this here is supposed to conj in-place
                $this = clojure::core::reduce1(\&Pajaro::AAssociative::_conjOneEntryInPlace, $this, clojure::core::seq($e));
            }
            elsif (!defined($e)) {
                ;
            }
            elsif ($e->isa('Pajaro::MapEntry') || (clojure::core::vector_QMARK_($e) && 2==clojure::core::count($e))) {
                $this = _conjOneEntryInPlace($this, $e)
            }
            else {
                die "MapEntry or 2-item Vector expected, not ".Pajaro::_type_name($e)
            }
        }
        $this
    }
    sub _dissocOneInPlace {
        my $this = shift;
        my $k = shift;
        my ($b, $j) = _findEntry($this, $k);
        if (defined($j)) {
            splice @{$b},$j,1,();
            $this->_clear_hash();
            --$$this[COUNT_SLOT];
            # MapEntrySeq does not tolerate empty buckets
            if (!@{$b}) {
                delete $$this[STUFF_SLOT]{&clojure::core::hash($k)};
            }
        }
        $this
    }
    sub _dissocInPlace {
        my $this = shift;
        my @kk = @_;
        for my $k (@kk) {
            $this = $this->_dissocOneInPlace($k);
        }
        $this
    }
    use overload '&{}' => '_code', 'fallback' => 1;
}

{
    package Pajaro::AMap;
    our @ISA = qw(Pajaro::AAssociative);
    sub _entriesFromKvkvs {
        my @kvs = @_;
        my @entries;
        die "Expected whole k,v pairs but got ".(0+@kvs) if ((@kvs % 2));
        for (my $i = 0; $i < @kvs; $i += 2) {
            my $k = $kvs[$i];
            my $v = $kvs[$i+1];
            my $e = new Pajaro::MapEntry($k, $v);
            push(@entries, $e);
        }
        @entries;
    }
    sub new_abstract_kvkvs {
        my $meta = shift;
        my @kvs = @_;
        my @entries = _entriesFromKvkvs(@kvs);
        Pajaro::AAssociative::new_abstract_entries($meta, @entries);
    }
    # IFind of AMap
    sub find {
        my $this = shift;
        my $k = shift;
        my ($b, $j) = $this->_findEntry($k);
        if (defined($j)) {
            $$b[$j]
        }
        else {
            undef
        }
    }
    # IKeysVals of AMap
    sub keys {
        my $this = shift;
        my $ret = $this->seq();
        if ($ret) { $ret->set_post_process_BANG_(\&clojure::core::key); }
        $ret
    }
    sub vals {
        my $this = shift;
        my $ret = $this->seq();
        if ($ret) { $ret->set_post_process_BANG_(\&clojure::core::val); }
        $ret
    }
    # ILookup (contains? is inherited)
    sub get {
        my $this = shift;
        my $k = shift;
        my $not_found = shift;
        my ($b, $j) = $this->_findEntry($k);
        defined($j) ? $$b[$j]->val() : $not_found
    }
    # IPr of AMap
    sub '-pr-str' {
        my $this = shift;
        my @particle = ('{');
        my $entrySep;
        for (my $s = $this->seq(), $entrySep=''; $s; $s=&clojure::core::next($s), $entrySep=', ') {
            my $e = clojure::core::_first($s);
            die "Unexpected nil first of non-nil seq" unless defined($e);
            push(@particle, $entrySep, clojure::core::pr_str(clojure::core::key($e)), ' ', clojure::core::pr_str(clojure::core::val($e)));
        }
        push(@particle, '}');
        join('', @particle);
    }
    # IPrint of AMap
    *_print_str = \*_pr_str;
    # ISeqable of AMap
    sub seq {
        my $this = shift;
        my @ks = CORE::keys(%{$$this[Pajaro::AAssociative::STUFF_SLOT]});
        if (@ks) {
            my $k = shift(@ks);
            my $bucket = $$this[Pajaro::AAssociative::STUFF_SLOT]{$k};
            new Pajaro::MapEntrySeq(
                undef, $$this[Pajaro::AAssociative::STUFF_SLOT], $bucket, 0, \@ks, undef)
        }
        else {
            undef
        }
    }
}

{
    package Pajaro::TransientMap;
    our @ISA = qw(Pajaro::AMap);
    # Important: same structure as COWMap. Re-bless a clone to switch.
    sub new {
        my $class = shift;
        bless Pajaro::AMap::new_abstract_kvkvs(@_), $class;
    }
    # ICloneable - from AMap
    # ICount - from AMap
    # IFind - from AMap
    # IEquiv - from AMap
    # IFn - from AMap
    # IHash - from AMap
    # IKeysVals - from AMap
    # ILookup - from AMap
    # IPr - from AMap
    # IPrint - from AMap
    # ISeqable - from AMap
    # ITransientAssoc of TransientMap
    sub 'assoc!' {
        my $this = shift;
        my @kvs = @_;
        # assoc! accepts an odd number of parameters and assumes the missing final one is nil.
        if (1 == @kvs % 2) {
            push(@kvs, undef);
        }
        $this->_assocInPlace(@kvs);
    }
    # ITransientCollection of TransientMap
    sub 'persistent!' {
        my $this = shift;
        my $ret = $this->clone();
        bless $this, 'Pajaro::Vacant';
        return bless $ret, 'Pajaro::COWMap';
    }
    # ITransientConj of TransientMap
    sub '-conj!' {
        my $this = shift;
        my @ee = @_;
        if (1 != @ee) {
            die "Single MapEntry expected"
        }
        else {
            $this->_conjEntriesInPlace(@ee);
        }
    }
    # ITransientDissoc of TransientMap
    sub 'dissoc!' {
        my $this = shift;
        my @kk = @_;
        $this->_dissocInPlace(@kk);
    }
}
_extend_type(_intern_type('Pajaro.TransientMap'),
             $clojure::core::ITransientAssoc,
             $clojure::core::IAssociative,
             $clojure::core::ICloneable,
             $clojure::core::ITransientCollection,
             $clojure::core::ITransientConj,
             $clojure::core::ICount,
             $clojure::core::ICounted,
             $clojure::core::ITransientDissoc,
             $clojure::core::IFind,
             $clojure::core::IEquiv,
             $clojure::core::IFn,
             $clojure::core::IHash,
             $clojure::core::IKeysVals,
             $clojure::core::ILookup,
             $clojure::core::IMap,
             $clojure::core::IMeta,
             $clojure::core::IPr,
             $clojure::core::IPrint,
             $clojure::core::ISeqable,
             $clojure::core::IWithMeta);

{
    package Pajaro::COWMap;

    # COWMap mutators do a deep clone, then use a transient mutator.

    our @ISA = qw(Pajaro::AMap);
    # Important: same structure as TransientMap. Re-bless a clone to switch.
    sub new { # class, meta, k, v, k, v, ...
        my $class = shift;
        bless Pajaro::AMap::new_abstract_kvkvs(@_), $class;
    }
    # IAssoc of COWMap
    sub assoc {
        my $this = shift;
        my @kvs = @_;
        $this->clone()->_assocInPlace(@kvs);
    }
    # ICloneable - from AMap
    # IConj of COWMap
    sub '-conj' {
        my $this = shift;
        my @ee = @_;
        $this->clone()->_conjEntriesInPlace(@ee);
    }
    # ICount - from AMap
    # IDissoc of COWMap
    sub dissoc {
        my $this = shift;
        my @kk = @_;
        $this->clone()->_dissocInPlace(@kk);
    }
    # IEditableCollection of COWMap
    sub transient {
        my $this = shift;
        my $ret = $this->clone();
        return bless $ret, 'Pajaro::TransientMap';
    }
    # IEmptyable of COWMap
    our $EMPTY = new Pajaro::COWMap();
    sub empty {
        my $this = shift;
        new Pajaro::COWMap($this->meta())
    }
    # IEquiv - from AMap
    # IFind - from AMap
    # IFn - from AMap
    # IHash - from AMap
    # IKeysVals - from AMap
    # ILookup - from AMap
    # IPr - from AMap
    # IPrint - from AMap
    # ISeqable - from AMap
}

_extend_type(_intern_type('Pajaro.COWMap'),
             $clojure::core::IAssoc,
             $clojure::core::IAssociative,
             $clojure::core::ICloneable,
             $clojure::core::ICollection,
             $clojure::core::IConj,
             $clojure::core::ICount,
             $clojure::core::ICounted,
             $clojure::core::IDissoc,
             $clojure::core::IEditableCollection,
             $clojure::core::IEmptyable,
             $clojure::core::IEquiv,
             $clojure::core::IFind,
             $clojure::core::IFn,
             $clojure::core::IHash,
             $clojure::core::IKeysVals,
             $clojure::core::ILookup,
             $clojure::core::IMap,
             $clojure::core::IMeta,
             $clojure::core::IPr,
             $clojure::core::IPrint,
             $clojure::core::ISeqable,
             $clojure::core::IWithMeta);

_intern('clojure.core','hash-map',sub{
    new Pajaro::COWMap(undef, @_);
        });

{
    package Pajaro::ASet;
    our @ISA = qw(Pajaro::AAssociative);
    sub _wrapItem {
        my $x = shift;
        new Pajaro::MapEntry($x,0)
    }
    sub new_abstract {
        my $meta = shift;
        my @items = @_;
        my @entries = map(_wrapItem($_), @items);
        Pajaro::AAssociative::new_abstract_entries($meta, @entries);
    }
    # IEquiv of ASet
    sub '-equiv' {
        my $this = shift;
        my $other = shift;
        if (!defined($other) || !&clojure::core::satisfies_QMARK_($clojure::core::ISet, $other)) {
            builtin::false
        }
        else {
            &Pajaro::_equiv_via_lookup($this, $other)
        }
    }
    # ILookup (inherit contains?)
    sub get {
        my $this = shift;
        my $k = shift;
        my $not_found = shift;
        my ($b, $j) = $this->_findEntry($k);
        defined($j) ? $$b[$j]->key() : $not_found
    }
    # IPr of ASet
    sub '-pr-str' {
        my $this = shift;
        my @particle = ('#{');
        my $sep='';
        for (my $s = $this->seq(); $s; $s=&clojure::core::next($s), $sep=' ') {
            my $e = clojure::core::_first($s);
            die "Unexpected nil first of non-nil seq" unless defined($e);
            push(@particle, $sep, clojure::core::pr_str($e));
        }
        push(@particle, '}');
        join('', @particle);
    }
    # IPrint of ASet
    *_print_str = \*_pr_str;
    # ISeqable of ASet
    sub seq {
        my $this = shift;
        my @ks = CORE::keys(%{$$this[Pajaro::AAssociative::STUFF_SLOT]});
        if (@ks) {
            my $k = shift(@ks);
            my $bucket = $$this[Pajaro::AAssociative::STUFF_SLOT]{$k};
            new Pajaro::MapEntrySeq(
                undef, $$this[Pajaro::AAssociative::STUFF_SLOT], $bucket, 0, \@ks, \&clojure::core::key)
        }
        else {
            undef
        }
    }
    sub _conjInPlace {
        my $this = shift;
        my @xs = @_;
        for my $x (@xs) {
            $this=$this->_conjOneEntryInPlace(_wrapItem($x));
        }
        $this
    }
}

{
    package Pajaro::TransientSet;
    our @ISA = qw(Pajaro::ASet);
    # Important: same structure as COWSet. Re-bless a clone to switch.
    sub new {
        my $class = shift;
        bless Pajaro::ASet::new_abstract(@_), $class;
    }
    # ICloneable - from ASet
    # ICount - from ASet
    # ICounted - marker
    # IEquiv - from ASet
    # IFn - from ASet
    # IHash - from ASet
    # ILookup - from ASet
    # IPr - from ASet
    # IPrint - from ASet
    # ISeqable - from ASet
    # ISet - marker
    # ITransientCollection of TransientSet
    sub 'persistent!' {
        my $this = shift;
        my $ret = $this->clone();
        bless $this, 'Pajaro::Vacant';
        return bless $ret, 'Pajaro::COWSet';
    }
    # ITransientConj of TransientSet
    sub '-conj!' {
        my $this = shift;
        my @ee = @_;
        $this = $this->_conjInPlace(@ee);
    }
    # ITransientDisj of TransientSet
    sub 'disj!' {
        my $this = shift;
        my @xs = @_;
        $this->_dissocInPlace(@xs);
    }
}
_extend_type(_intern_type('Pajaro.TransientSet'),
             $clojure::core::ICloneable,
             $clojure::core::ICount,
             $clojure::core::ICounted,
             $clojure::core::IEquiv,
             $clojure::core::IFn,
             $clojure::core::IHash,
             $clojure::core::ILookup,
             $clojure::core::IPr,
             $clojure::core::IPrint,
             $clojure::core::ISeqable,
             $clojure::core::ISet,
             $clojure::core::ITransientCollection,
             $clojure::core::ITransientConj,
             $clojure::core::ITransientDisj);

{
    package Pajaro::COWSet;

    # COWSet mutators do a deep clone, then use a transient mutator.

    our @ISA = qw(Pajaro::ASet);
    # Important: same structure as TransientSet. Re-bless a clone to switch.
    sub new {
        my $class = shift;
        bless Pajaro::ASet::new_abstract(@_), $class;
    }
    # ICloneable - from ASet
    # IConj of COWSet
    sub '-conj' {
        my $this = shift;
        my @xs = @_;
        $this->clone()->_conjInPlace(@xs);
    }
    # ICount - from ASet
    # ICounted - marker
    # IDisj of COWSet
    sub disj {
        my $this = shift;
        my @xs = @_;
        $this->clone()->_dissocInPlace(@xs);
    }
    # IEditableCollection of COWSet
    sub transient {
        my $this = shift;
        my $ret = $this->clone();
        return bless $ret, 'Pajaro::TransientSet';
    }
    # IEmptyable of COWSet
    our $EMPTY = new Pajaro::COWSet();
    sub empty {
        my $this = shift;
        new Pajaro::COWSet($this->meta())
    }
    # IEquiv - from ASet
    # IFn - from ASet
    # IHash - from ASet
    # ILookup - from ASet
    # IPr - from ASet
    # IPrint - from ASet
    # ISeqable - from ASet
    # ISet - marker
}
_extend_type(_intern_type('Pajaro.COWSet'),
             $clojure::core::ICloneable,
             $clojure::core::ICollection,
             $clojure::core::IConj,
             $clojure::core::ICount,
             $clojure::core::ICounted,
             $clojure::core::IDisj,
             $clojure::core::IEditableCollection,
             $clojure::core::IEquiv,
             $clojure::core::IEmptyable,
             $clojure::core::IFn,
             $clojure::core::IHash,
             $clojure::core::ILookup,
             $clojure::core::IMeta,
             $clojure::core::IPr,
             $clojure::core::IPrint,
             $clojure::core::ISeqable,
             $clojure::core::ISet,
             $clojure::core::IWithMeta);

_intern('clojure.core','hash-set',sub{
    new Pajaro::COWSet(undef, @_);
        });

###--- Symbol and Keyword

{
    package Pajaro::ASymbol;

    use constant { NAME_SLOT=> 2 };
    use constant { NAMESPACE_SLOT=> 3 };

    sub init {
        my $self = shift;
        my @naming = @_;
        $$self[NAME_SLOT]=shift @naming;
        die "Unlikely symbol name $$self[NAME_SLOT]" if ($$self[NAME_SLOT] =~ /::/);
        die "Unlikely symbol name $$self[NAME_SLOT]" if ($$self[NAME_SLOT] =~ /_COLON__COLON_/);
        $$self[NAMESPACE_SLOT] = shift @naming;
        $self
    }
    sub name {
        my $this = shift;
        $$this[NAME_SLOT]
    }
    sub namespace {
        my $this = shift;
        $$this[NAMESPACE_SLOT]
    }
    sub __pr_str {
        my $this = shift;
        my @slugs;
        if (defined($$this[NAMESPACE_SLOT])) {
            push(@slugs, $$this[NAMESPACE_SLOT]);
            push(@slugs, '/')
        }
        push(@slugs, $$this[NAME_SLOT]);
        join('', @slugs)
    }
    sub _equiv {
        my $this = shift;
        my $o = shift;
        $this && $o
            && ref($this) && ref($o)
            && ref($this) eq ref($o)
            && $$this[NAME_SLOT] eq $$o[NAME_SLOT]
            && ((!defined($$this[NAMESPACE_SLOT]) && !defined($$o[NAMESPACE_SLOT]))
                || ($$this[NAMESPACE_SLOT] && $$o[NAMESPACE_SLOT]
                    && $$this[NAMESPACE_SLOT] eq $$o[NAMESPACE_SLOT]))
            ? builtin::true : builtin::false
    }
    sub 'qualified?' {
        my $this = shift;
        $$this[NAMESPACE_SLOT] ? builtin::true : builtin::false
    }
    sub _code {
        my $this = shift;
        sub {
            my $coll = shift;
            my $not_found = shift; # optional
            return clojure::core::get($coll, $this, $not_found);
        }
    }
    sub compare {
        my $this = shift;
        my $o = shift;
        if (!defined($o)) { 1 }
        elsif (clojure::core::satisfies_QMARK_($clojure::core::INamespaced, $o)) {
            clojure::core::compare($this->namespace, clojure::core::namespace($o))
                || clojure::core::compare($this->name, clojure::core::name($o))
        }
        else {
            die "Not comparable"
        }
    }
    use overload '&{}' => '_code', 'fallback' => 1;
}

{
    package Pajaro::Symbol;
    our @ISA=qw(Pajaro::ASymbol Pajaro::AWithMeta);

    sub new {
        my $class = shift;
        my $meta = shift;
        my $self = Pajaro::AWithMeta::new_abstract($meta);
        Pajaro::ASymbol::init($self, @_);
        return bless $self, $class;
    }
    *_pr_str = \&Pajaro::ASymbol::__pr_str;
    *_print_str = \&Pajaro::ASymbol::__pr_str;
    sub clone {
        my $this = shift;
        my $ret = +[@{$this}];
        bless($ret, ref($this));
    }
    sub _hash {
        my $this = shift;
        Pajaro::Murmur3::hashSymbol($$this[Pajaro::ASymbol::NAMESPACE_SLOT],
                                  $$this[Pajaro::ASymbol::NAME_SLOT])
    }
}
_extend_type(_intern_type('Pajaro.Symbol'),
             $clojure::core::ICloneable,
             $clojure::core::IComparable,
             $clojure::core::IEquiv,
             $clojure::core::IFn,
             $clojure::core::IHash,
             $clojure::core::IMeta,
             $clojure::core::INamed,
             $clojure::core::INamespaced,
             $clojure::core::IPr,
             $clojure::core::IPrint,
             $clojure::core::IWithMeta,
    );

_intern('clojure.core','symbol',sub {
    if (2==@_) {
        my $ns = shift; my $n = shift;
        if (defined($ns) && !defined($n)) {
	    die 'Symbol with namespace must have name' }
        if (defined($ns) && ref($n)) {
	    die 'Symbol: if ns is non-nil, name must be string' }
        if (defined($ns) && ref($ns)) {
	    die 'Namespace of symbol must be string' }
        new Pajaro::Symbol(undef, $n, $ns)
    }
    elsif (1==@_ && 'Pajaro::Var' eq ref($_[0])) {
        my $v = shift;
        my $ns = $v->get_namespace();
        my $n = $v->get_name();
        new Pajaro::Symbol(undef, $n, $ns)
    }
    elsif (1==@_ && 'Pajaro::Symbol' eq ref($_[0])) {
        my $sym = shift;
	$sym->clone();
    }
    else {
        my $n = shift;
	my $ns = undef;
        if (!defined($n)) { die "Name is required" }
        if(ref($n)) {
            $n = &clojure::core::name($n)
        }; # in case it was a Symbol or Keyword. But beware, name("")=nil and we must allow empty string as keyword name
	if (!defined($ns) && $n =~ m,([^/]*)/(.+),) {
	    $ns=$1; $n=$2;
	}
        new Pajaro::Symbol(undef, $n, $ns)
    }
        });

_extend_type(_intern_type('Pajaro.Namespace'),
             $clojure::core::INamespace, +{'ns-name'=>sub {
                 my $ans = shift;
                 my $nm = $ans->get_name();
                 clojure::core::symbol($nm);
                                  }});

_intern('clojure.core','-symbol-from-var', sub{
    my $v=shift;
    clojure::core::symbol($v->get_namespace(), $v->get_name());
        });

{
    package Pajaro::Keyword;
    our @ISA=qw(Pajaro::AHash Pajaro::ASymbol);

    sub new {
        my $class = shift;
        my $self = Pajaro::AHash::new_abstract();
        Pajaro::ASymbol::init($self, @_);
        return bless $self, $class;
    }
    sub _pr_str {
        my $this = shift;
        ':'.Pajaro::ASymbol::__pr_str($this)
    }
    *_print_str = \*_pr_str; # IPrint
    sub _hash {
        my $this = shift;
        Pajaro::Murmur3::hashKeyword($$this[Pajaro::ASymbol::NAMESPACE_SLOT],
                                   $$this[Pajaro::ASymbol::NAME_SLOT])
    }
}
_extend_type(_intern_type('Pajaro.Keyword'),
             $clojure::core::IComparable,
             $clojure::core::IEquiv,
             $clojure::core::IFn,
             $clojure::core::IHash,
             $clojure::core::INamed,
             $clojure::core::INamespaced,
             $clojure::core::IPr,
             $clojure::core::IPrint,
    );

# Keywords are interned - should be compared with `identical?`.
# Hash of keyword-pr-str => Keyword (or undef if weak ref got collected).
our %KEYWORDS;

_intern('clojure.core', 'find-keyword', # [name] or [ns name]
        sub {
            my $ns;
            my $n;
            if (@_ == 2) { $ns = shift; }
            $n = shift;
            my $kw=new Pajaro::Keyword($n, $ns);
            my $p=(0+length($ns//'')).$kw->_pr_str();
            return $KEYWORDS{$p};
        });
_intern('clojure.core', 'keyword', # [name] or [ns name]
        sub {
            my $ns;
            my $n;
            if (@_ == 2) { $ns = shift; }
            $n = shift;
            if (defined($ns) && !defined($n)) {
		die 'Keyword with namespace must have name' }
            if (defined($ns) && ref($n)) {
		die 'Keyword: if ns is non-nil, name must be string' }
            if (!defined($n)) { return undef; }
            if(ref($n)) {$n = &clojure::core::name($n)}; # in case it was a Symbol or Keyword. But beware, name("")=nil and we must allow empty string as keyword name
            if(defined($ns) && ref($ns)) {
		die 'Namespace of keyword must be string' }
	    if (!defined($ns) && $n =~ m,([^/]*)/(.+),) {
		$ns=$1; $n=$2;
	    }
            my $kw=new Pajaro::Keyword($n, $ns);
            my $p=(0+length($ns//'')).$kw->_pr_str();
            $KEYWORDS{$p} || ($KEYWORDS{$p}=$kw);
        });

our $KW_DYNAMIC = clojure::core::keyword('dynamic');
our $KW_MACRO = clojure::core::keyword('macro');
our $KW_NAME = clojure::core::keyword('name');
our $KW_NS = clojure::core::keyword('ns');
our $KW_FILE = clojure::core::keyword('file');
our $KW_LINE = clojure::core::keyword('line');
our $KW_COL = clojure::core::keyword('col');
our $KW_DEFAULT = clojure::core::keyword('default');
our $KW_PAJARO_CLJPL = clojure::core::keyword('pajaro','cljpl');
our $KW_APPLY_SPLAT = clojure::core::keyword('apply-splat');
our $KW_ACCEPT_APPLY_SPLAT = clojure::core::keyword('accept-apply-splat');

# With Symbol now a possible argument to _intern,
# Extract source-code location metadata to structure used by Perl code emitter
sub _citation_and_user_meta {
    my $x = shift;
    my $m = clojure::core::meta($x);
    my $cite=+[&clojure::core::get($m, $KW_LINE),
	       &clojure::core::get($m, $KW_FILE)];
    return ($cite, $m);
}

_intern('clojure.core','ident?', sub {
    clojure::core::satisfies_QMARK_($clojure::core::INamed, $_[0])
        && clojure::core::satisfies_QMARK_($clojure::core::INamespaced, $_[0])});

_intern('clojure.core','qualified-ident?',
     sub {
         die('arity') unless (@_ == 1);
         my $x = shift;
         return clojure::core::boolean(clojure::core::ident_QMARK_($x)
                        && defined($x->namespace()));
     });

_intern('clojure.core','simple-ident?',
     sub {
         die('arity') unless (@_ == 1);
         my $x = shift;
         return clojure::core::boolean(clojure::core::ident_QMARK_($x)
                        && !defined($x->namespace()));
        });

_intern('clojure.core','symbol?', sub {
    my $kw = shift;
    my $t = type($kw);
    return clojure::core::boolean($t && ('Pajaro.Symbol' eq $t->name()));
     });

_intern('clojure.core','qualified-symbol?',
     sub {
         die('arity') unless (@_ == 1);
         my $kw = shift;
         if(!$kw){return builtin::false}
         return clojure::core::boolean('Pajaro.Symbol' eq clojure::core::type($kw)->name() && clojure::core::qualified_ident_QMARK_($kw));
     });

_intern('clojure.core','simple-symbol?',
     sub {
         die("arity") unless (@_ == 1);
         my $kw = shift;
         if(!$kw){return builtin::false}
         return clojure::core::boolean('Pajaro.Symbol' eq clojure::core::type($kw)->name() && clojure::core::simple_ident_QMARK_($kw));
     });

_intern('clojure.core','keyword?', sub {
    my $kw = shift;
    if(!$kw){return builtin::false}
         return clojure::core::boolean('Pajaro.Keyword' eq clojure::core::type($kw)->name());
     });

_intern('clojure.core','qualified-keyword?',
     sub {
         die('arity') unless (@_ == 1);
         my $kw = shift;
         if(!$kw){return builtin::false}
         return clojure::core::boolean('Pajaro.Keyword' eq clojure::core::type($kw)->name()
                        && clojure::core::qualified_ident_QMARK_($kw));
     });

_intern('clojure.core','simple-keyword?',
     sub {
         die('arity') unless (@_ == 1);
         my $kw = shift;
         if(!$kw){return builtin::false}
         return clojure::core::boolean('Pajaro.Keyword' eq clojure::core::type($kw)->name()
                        && clojure::core::simple_ident_QMARK_($kw));
        });

###--- Var (additions)

our $dynamic_var_metadata = clojure::core::hash_map($Pajaro::KW_DYNAMIC, 1);

clojure::core::reset_meta_BANG_($clojure::core::_STAR_print_meta_STAR_,
                          $dynamic_var_metadata);

# Complete Var by assigning its name and namespace to metadata.
{
    package Pajaro::Var;
    no warnings qw(redefine);
    # NB: assigned via typeglob, not `sub assign_name_ns_meta {...}`, because a
    # named sub declaration is bound at COMPILE time (so it would shadow the
    # no-op stub above for the entire file, before clojure::core::symbol/_the_ns exist
    # at runtime). Glob assignment only takes effect when execution reaches
    # this statement, by which point clojure::core::symbol (interned above) is ready.
    *assign_name_ns_meta = sub {
        my $this = shift;
        my $name = shift || $$this[NAMED_NAME_SLOT];
        my $namespace = shift || $$this[NAMED_NS_SLOT];

        if ('' eq ref($name)) {
            $name = clojure::core::symbol($name);
        }
        if ('' eq ref($namespace)) {
            $namespace = clojure::core::_the_ns($namespace);
        }

        my $m = $this->meta();
        if (!defined($m)) { $m = clojure::core::hash_map(); }

        if ('Pajaro::Symbol' ne ref($name)) {
            die "Name should be a Symbol";
        }
        if ('Pajaro::Namespace' ne ref($namespace)) {
            die "Namespace should be a Namespace";
        }

        $m = $m->assoc($KW_NAME, $name)->assoc($KW_NS, $namespace);
        $this->reset_meta_BANG_($m);
        undef;
    };
}

# Backfill the :name and :ns metadata of existing Var instances:
{
    no strict 'refs';
    for my $name (keys %clojure::core::) {
        my $var = ${"clojure::core::$name"};
        if ('Pajaro::Var' eq ref($var)) {
            $var->assign_name_ns_meta();
        }
    }
}

_intern('clojure.core','bound?',
        sub {
            for my $v (@_) {
                if (_is_the_unbound(&clojure::core::var_get($v))) {
                    return builtin::false;
                }
            }
            builtin::true
        });

_intern('clojure.core','find-var',
        sub {
            my $sy = shift;
            die 'Symbol must be namespace-qualified'
                unless &clojure::core::qualified_symbol_QMARK_($sy);
            my $nsdots = &clojure::core::namespace($sy);
            my $vclj = &clojure::core::name($sy);
            # If nsdots is an alias, replace it.
            my %aliases = %{clojure::core::deref($clojure::core::_STAR_ns_STAR_)->aliases()};
            if (exists($aliases{$nsdots})) {
                my $aliased_ns=$aliases{$nsdots};
                $nsdots = $aliased_ns->get_name();
            }
            my $vpl = munge($vclj);
            my $nspl = _namespace_munge($nsdots);
            no strict 'refs';
            if (exists(${"${nspl}::"}{$vpl})) {
                ${"${nspl}::$vpl"}
            }
            else {
                undef
            }
        }
    );

_intern('clojure.core', 'find-ns',
        sub {
            my $x = shift;
            if ('Pajaro::Symbol' ne ref($x)) { die "Not a symbol" }
            else {
                my $dqname = clojure::core::name($x);
                if (!exists($NAMESPACES{$dqname})) {
                    return undef;
                }
                else {
                    return $NAMESPACES{$dqname};
                }
            }
        });

_intern('clojure.core', 'the-ns',
        sub {
            my $nsclue = shift;
            if ('Pajaro::Namespace' eq ref($nsclue)) { return $nsclue; }
            elsif ('Pajaro::Symbol' ne ref($nsclue)) { die "Not a symbol" }
            else {
                my $ret = &clojure::core::find_ns($nsclue);
                if (!$ret) {
                    die "No namespace found: ".clojure::core::pr_str($nsclue);
                }
                return $ret;
            }
        });

###--- Standard file handles

{
    my $fh = new FileHandle;
    $fh->fdopen(fileno(STDOUT),'w');
    binmode($fh, ':encoding(UTF-8)'); # *out* holds code points, not bytes
    _intern('clojure.core', clojure::core::with_meta(clojure::core::symbol('*out*'),
                                      $dynamic_var_metadata), $fh);
}
{
    my $fh = new FileHandle;
    $fh->fdopen(fileno(STDERR),'w');
    binmode($fh, ':encoding(UTF-8)');
    _intern('clojure.core', clojure::core::with_meta(clojure::core::symbol('*err*'),
                                      $dynamic_var_metadata), $fh);
}
{
    my $fh = new FileHandle;
    $fh->fdopen(fileno(STDIN),'r');
    binmode($fh, ':encoding(UTF-8)');
    _intern('clojure.core', clojure::core::with_meta(clojure::core::symbol('*in*'),
                                      $dynamic_var_metadata), $fh);
}

###--- Printing (to files)

_intern('clojure.core','print',
       sub {
           my $sep='';
           for my $x (@_) {
               no warnings;
               print ${$clojure::core::_STAR_out_STAR_} $sep; # *out*
               my $s =
                   (clojure::core::satisfies_QMARK_($clojure::core::IPrint, $x))
                   ? clojure::core::_print_str($x)
                   : "$x";
               print ${$clojure::core::_STAR_out_STAR_} $s;   # *out*
               $sep=' ';
           }
           undef
        });

_intern('clojure.core','pr',
       sub {
           my $sep='';
           for my $x (@_) {
               no warnings;
               print ${$clojure::core::_STAR_out_STAR_} $sep; # *out*
               my $s =
                   (clojure::core::satisfies_QMARK_($clojure::core::IPr, $x))
                   ? clojure::core::_pr_str($x)
                   : "$x";
               print ${$clojure::core::_STAR_out_STAR_} $s;   # *out*
               $sep=' ';
           }
           undef
        });

###--- Var: notify watchers

{
    package Pajaro::Var;

    no warnings 'redefine';

    *_notify_watches = sub {
	my $this = shift;
	my $o = shift;
	my $n = shift;
	my $watchers = $$this[VAR_WATCHERS_SLOT];
	if ($watchers) {
	    for(my $watcher_seq = clojure::core::seq($watchers); $watcher_seq; $watcher_seq = clojure::core::next($watcher_seq)) {
		my $watcher = clojure::core::first($watcher_seq);
		my $k = clojure::core::key($watcher);
		my $f = clojure::core::val($watcher);
		&{$f}($k,$this,$o,$n);
	    }
	}
    };

    sub add_watch {
	my $this = shift;
	my $k = shift;
	my $f = shift;
	# if no watcher map yet, establish a transient
	# stash the watch
	if (!$$this[VAR_WATCHERS_SLOT]) {
	    $$this[VAR_WATCHERS_SLOT] = Pajaro::TransientMap->new();
	}
	$$this[VAR_WATCHERS_SLOT] = clojure::core::assoc_BANG_($$this[VAR_WATCHERS_SLOT], $k, $f);
	$this
    }

    sub remove_watch {
	my $this = shift;
	my $k = shift;
	# if there is a watcher map
	# remove the key
	if ($$this[VAR_WATCHERS_SLOT]) {
	    $$this[VAR_WATCHERS_SLOT] = clojure::core::dissoc_BANG_($$this[VAR_WATCHERS_SLOT], $k);
	}
	$this
    }
}

###--- Dynamic variables

_intern('clojure.core',
	clojure::core::with_meta
	(clojure::core::symbol('*verbose*'), $dynamic_var_metadata),
	$Pajaro::VERBOSE);

_intern('clojure.core',
	clojure::core::with_meta
	(clojure::core::symbol('*path*'), $dynamic_var_metadata),
	$Pajaro::PATH || '.');

_intern('clojure.core',
	clojure::core::with_meta
	(clojure::core::symbol('*compile-path*'), $dynamic_var_metadata),
	$Pajaro::COMPILE_PATH || '.');

_intern('clojure.core',
	clojure::core::with_meta
	(clojure::core::symbol('*assert*'), $dynamic_var_metadata),
	builtin::true);

for my $i ('*1','*2','*3','*e') {
    _intern('clojure.core',
	    clojure::core::with_meta
	    (clojure::core::symbol($i), $Pajaro::dynamic_var_metadata));
}

###--- Macros and hygiene

# Forward-declare macroexpand_1 and macroexpand
#  important! not \&identity because updating the Var later would redefine it!
*clojure::core::macroexpand_1 = sub { my $x = shift; return $x; };
*clojure::core::macroexpand   = sub { my $x = shift; return $x; };

our $GENSYM_COUNTER=0;

_intern('clojure.core', 'genlocal', # returns a name for a variable
        sub {
            my $prefix = (shift // 'G__');
            if (ref($prefix)) { $prefix = clojure::core::name($prefix); } # transform Symbol to string
            die "Unusual gensym prefix $prefix" if ($prefix =~ /::|_COLON__COLON_/);
            $prefix.($GENSYM_COUNTER++);
        });

_intern('clojure.core', 'gensym', # returns a Symbol for a variable
        sub {
            new Pajaro::Symbol(undef, clojure::core::genlocal(@_))
        });

_intern('clojure.core', 'rationalize*', # without simplifying the result
	sub {
	    my $x = shift;
	    my $xt = _type_name($x);
	    if ('Math.BigFloat' eq $xt) {
		$x->as_rat()
	    }
	    elsif ('Pajaro.Double' eq $xt) {
		# heuristic from Claude
		for my $p (15 .. 17) {
		    my $s = sprintf("%.${p}g", $x);
		    return Math::BigRat->new($s) if $s == $x;
		}
	    }
	    else {
		$x
	    }
	});

###--- clojure.core functions required by the Reader

_intern('clojure.core', 'reduce1', ## requires IFirstRest and INext ## no reduced?
     sub {
         my @args = @_;
         my $f = $args[0];
         my $coll;
         my $val;
         if (2 == @args) {
             $coll = $args[1];
             my $s = clojure::core::seq($coll);
             if (!$s) {
                 return &$f();
             }
             else {
                 $val = &clojure::core::_first($s);
                 $coll = &clojure::core::next($s);
             }
         }
         elsif (3 == @args) {
             $val = $args[1];
             $coll = $args[2];
         }
         else {
             die "reduce requires 2 or 3 arguments";
         }
         for (my $s = clojure::core::seq($coll); $s; $s=&clojure::core::next($s)) {
             my $a = &clojure::core::_first($s);
             my $val1 = &$f($val, $a);
             $val = $val1;
         }
         return $val;
     });

_intern('clojure.core', 'merge',
        sub {
            my @args = @_;
            my $map1 = shift(@args); # might be nil
            my $others = clojure::core::seq(\@args);
            return clojure::core::reduce1
                (sub {
                    my $x = shift;
                    my $y = shift;
                    if (!defined($x)) {
                        $y
                    }
                    else {
                        # y might be nil
                        if (!defined($y)) {
                            $x
                        }
                        # y might be a single MapEntry
                        elsif (clojure::core::map_entry_QMARK_($y)
                            || clojure::core::vector_QMARK_($y)) {
                            clojure::core::conj($x, $y)
                        }
                        # y might be a Map (collection of entries)
                        elsif (clojure::core::map_QMARK_($y)) {
                            clojure::core::reduce1
                                (\&clojure::core::conj,
                                 $x,
                                 clojure::core::seq($y))
                        }
                        # else undefined
                        else {
                            die("Unmergeable")
                        }
                    }
                 },
                 $map1,
                 $others);
        });

_intern('clojure.core', 'concat1', # eager (not lazy)
        sub {
            my @colls = @_;
            my @agglomerated;
            for my $coll (@colls) {
                for (my $s = clojure::core::seq($coll); $s; $s=&clojure::core::next($s)) {
                    push(@agglomerated, clojure::core::first($s));
                }
            }
            return clojure::core::list(@agglomerated);
        });

_intern('clojure.core', 'vary-meta',
        sub {
            my $o0 = shift;
            my $f = shift;
            my @f_args = @_;
            my $m0 = clojure::core::meta($o0);
            my $m1 = &{$f}($m0, @f_args);
            my $o1 = &clojure::core::with_meta($o0, $m1);
            return $o1;
        });

# Seq of the args, wherein the final arg, a collection, is unrolled
# ClojureScript's spread function seems to be similar to list* in Clojure
_intern('clojure.core','spread', # spread is a feature of ClojureScript
      sub {
          my @args = @_;
          my $n = 0+@args;
          if (0 == $n) {
              undef;
          }
          elsif (1==$n) {
              clojure::core::seq($args[0]);
          }
          else {
              my $a = $args[0];
              shift @args;
              clojure::core::cons($a, clojure::core::spread(@args));
          }
      });

# The last parameter is a Clojure collection. Returns a Perl array
# holding items 0 to butlast of the parameters, plus the first items
# of the last-parameter Clojure collection if necessary to reach the
# threshold of 20 ordinary items, followed by a Clojure collection of
# the remainder of that last parameter's members, annotated with
# metadata :apply-splat true. The threshold of 20 is the limit on the
# number of positional parameters and ensures that the apply-splat
# parameter, if any, will be in the called function's varargs bucket.
sub _spreadapply {
    my @args = @_;
    my $n = 0+@args;
    if (0 == $n) {
        +[]
    }
    else {
        my @r;
        my $i;
        for ($i=0; $i<($n-1); $i++) {
            my $item = shift(@args);
            push(@r,$item);
        }
        # @args has one item left, a Clojure collection.
        # Peel the first few items to complete 20 ordinaries.
        my $coll = $args[0];
        while (clojure::core::seq($coll) && $i < 20) {
            push(@r, clojure::core::first($coll));
            $coll = &clojure::core::next($coll);
            $i++;
        }
        # Any still remaining, annotate the collection:
        if(clojure::core::seq($coll)) {
            push(@r, clojure::core::vary_meta($coll, \&clojure::core::assoc, clojure::core::keyword('apply-splat'), builtin::true));
        }
        \@r
    }
}

_intern('clojure.core','vec', # caution: vec is also a Perl built-in
     sub {
         my $coll = shift;
         if (clojure::core::vector_QMARK_($coll)) {
             $coll
         }
         elsif ('ARRAY' eq ref($coll)) {
             Pajaro::COWVector->new_alias(undef, $coll)
         }
         else {
             my $m = new Pajaro::COWVector()->transient();
             for (my $x=clojure::core::seq($coll); $x; $x=&clojure::core::next($x)) {
                 $m = clojure::core::conj_BANG_($m, clojure::core::first($x));
             }
             $m->persistent_BANG_()
         }
      });

_intern('clojure.core','apply',
      sub {
          my $f = shift;
          my @args = @_;
          my $perl_list;
          my $code = clojure::core::_code($f);
          if (clojure::core::get(clojure::core::meta($f),$Pajaro::KW_ACCEPT_APPLY_SPLAT)
              && clojure::core::satisfies_QMARK_($clojure::core::IWithMeta, $args[$#args])) {
              # Tag the last @args member instead of splatting it - it might be lazy/infinite.
              $perl_list = _spreadapply(@args);
          }
          else {
              my $v = &clojure::core::vec(clojure::core::spread(@args)); # splats the final @args member
              $perl_list = clojure::core::_perl_array($v);
          }
          return &{$code}(@{$perl_list});
      });

###--- Perl regular expression primitives

_intern('clojure.core','re-pattern', sub{my$s=shift;qr($s)});

_intern('clojure.core','re-find',
        sub {
            my$r=shift;
            my$s=shift;
            # Test the match's own result, not defined($&): a failed match
            # leaves $& holding a stale value from an earlier successful
            # match in an enclosing dynamic scope.  In list context a match
            # returns () on failure, (1) on success without groups, or the
            # (possibly undef) group values.
            my@a=($s=~$r);
            if(!@a){
                undef
            }
            else{
                if(1==@a && clojure::core::boolean_QMARK_($a[0])){
                    "$&"
                }
                else{
                    clojure::core::vector("$&",@a);
                }
            }
        });

###--- Reader and code emitter

require Pajaro::Reader;

require Pajaro::Salt;

###--- Transpiler

# Dotted simple symbol made from *ns* + given symbol.
# Dies if given symbol is ns-qualified.
# Passes through if simple dot-qualified.
sub _simple_symbol_default_ns_dotted {
    my $symbol = shift;
    if ($symbol->namespace()) {
        die "Qualified"
    }
    else {
        my $sym_name = $symbol->name();
        if ($sym_name =~ /[.]/) {
            $symbol
        }
        else {
            clojure::core::symbol
                (clojure::core::name(clojure::core::ns_name(clojure::core::deref($clojure::core::_STAR_ns_STAR_)))
                 . '.' . $symbol->name())
        }
    }
}

_intern('clojure.core', 'ns-resolve', # Var or Type ; nil if not found
        sub {
            my $nsclue = shift;
            my $env;
            my $sy;
            if (1<@_) { $env=shift; }
            $sy=shift;
            if ($env) {
                print STDERR " ns-resolve ought to check local env, ".Data::Dumper::Dumper($env)."\n";
            }
            my $ret;
            if (&clojure::core::qualified_symbol_QMARK_($sy)) {
                $ret = &clojure::core::find_var($sy); # honors ns aliases
            }
            else {
                my $ns = &clojure::core::the_ns($nsclue);
                my $a=&clojure::core::name($sy);
                my $ns_intern_ref=$ns->contents()->{$a};
                if (clojure::core::var_QMARK_($ns_intern_ref)) {
                    $ret = $ns_intern_ref;
                }
            }
            $ret
        });

_intern('clojure.core', 'resolve',
        sub {
            &clojure::core::ns_resolve(clojure::core::deref($clojure::core::_STAR_ns_STAR_), @_);
        });

_intern('clojure.core', 'ns-unmap',
        sub {
            my $nsclue = shift; # un-munged
            my $sym = shift;
            my $ns = &clojure::core::the_ns($nsclue);
            $ns->unmapVarName(clojure::core::name($sym));
        });

require Pajaro::Transpiler;

use Pajaro::HOPerl;

###--- Reflection

# If it is a Var - then the value in the Var
# If it is a non-Var scalar - then its value
# If it is a function - then a reference to the function
# If it does not exist - then throw
# Perl creates CORE::name subs lazily, on first mention of &CORE::name,
# so they are absent from the stash until then. Probing with defined(&...)
# creates the real one, and creates nothing for a name that is not a core function.
sub _vivify_core_sub {
    my $nspl=shift;
    my $vpl=shift;
    no strict 'refs';
    if ($nspl eq 'CORE') {
        my $probe = defined(&{"CORE::${vpl}"});
    }
}

sub _reflect_qualified_symbol {
    my $nspl=shift;
    my $vpl=shift;
    no strict 'refs';
    _vivify_core_sub($nspl, $vpl);
    if (exists(${"${nspl}::"}{$vpl})) {
        my $scalar = ${"${nspl}::$vpl"};
        if (defined($scalar)) {
            my $p = $scalar;
            if (&clojure::core::var_QMARK_($p)) {
                $p = clojure::core::deref($p);
            }
            return $p;
        }
        # defined(&{NAME}) does not autovivify a stub, whereas \&{NAME} does
        elsif (defined(&{"${nspl}::$vpl"})) {
            return \&{"${nspl}::$vpl"};
        }
        else {
            # The slot holds neither a scalar nor a sub
            die "Slot is empty: ${nspl}::${vpl}";
        }
    }
    else {
        if (exists(${"${nspl}::"}{"${vpl}::"})) {
            return "${nspl}::${vpl}"; # perfect Perl syntax for new PKG(...)
        }
        else {
            # No such slot
            die "Slot not found: ${nspl}::${vpl}";
        }
    }
}

sub _reflect_dotted_symbol {
    shift; # ignore the namespace. The dotted simple symbol should stand on its own
    my $nm=shift;
    no strict 'refs';
    my @nmparts = split(/[.]/,$nm);
    my $last = pop(@nmparts);
    my $nspl = join('::', map(munge($_), @nmparts));
    my $vpl = munge($last);
    if (exists(${"${nspl}::"}{"${vpl}::"})) {
        return "${nspl}::${vpl}"; # perfect Perl syntax for new PKG(...)
    }
    else {
        # No such slot
        die "Slot not found: ${nspl}::${vpl}::";
    }
}

###--- Evaluation, AOT compilation, and loading

our $COMPILE_TO_FILEHANDLE;
# Perl of the current file's top-level forms, kept until gen-class opens the output
our $FILE_PERL;

_intern('clojure.core', 'perl-eval', # scalar context. Throws $@
      sub {
          my $perl_text = shift;
          undef $@;
          my $ret = eval($perl_text);
          if ($@) { die $@ }
          $ret
      });

_intern('clojure.core','eval',
        sub {
            my $form = shift;
            my $opts = +{};
            my $env = +{};
            my $p = Pajaro::Salt::toPerl
                (Pajaro::Transpiler::transpile($opts, $form, $env));

            # Newline after warning suppression b/c the first line of Perl might be a line-setting comment, which must be in column 1
            $p = "no strict;no warnings qw(redefine void experimental::builtin);\npackage "
                . _namespace_munge(clojure::core::deref($clojure::core::_STAR_ns_STAR_)->get_name()).";\n$p";
            push(@$FILE_PERL, $p) if $FILE_PERL && !$COMPILE_TO_FILEHANDLE;

            if ($COMPILE_TO_FILEHANDLE) {
                print $COMPILE_TO_FILEHANDLE "$p;\n";
            }
            if (clojure::core::deref($clojure::core::_STAR_verbose_STAR_)) {
                print STDERR "$p\n";
            }
            &clojure::core::perl_eval($p)
        });

_intern('clojure.core', clojure::core::with_meta(clojure::core::symbol('*compile-files*'),
                                $Pajaro::dynamic_var_metadata),
        $main::compile_files ? builtin::true : builtin::false);

sub _eval_multi_line_string { # returns value of the last form
    my $filename_for_citation=shift;
    my $stuf = shift;
    my $opts = +{'init-cursor'=>+{'FILE'=>$filename_for_citation,
                                      'LINE'=>1}};
    my $eval_override = shift // \&clojure::core::eval;
    my $a;
    for(;;) {
        if (! $stuf) {
            last;
        }
        my $r = Pajaro::Reader::read_PLUS_string($opts, $stuf);
        $$opts{'init-cursor'} = +{%{$$opts{'init-cursor'}}, %{$r->{'end-cursor'}}};
        my $form = $r->{'form'};
        if (! ('Pajaro::Reader::Nothing' eq ref($form))) {
            my @forms = ($form);
            # macroexpand (slightly), and if 'do' is in function position,
            # perform each of its forms independently.
            # Purpose: (do (deftype* Foo ...) (defn ->Foo (. Foo new ...)))
            #  or similar series in which each form within 'do' must
            #  be fully evaluated before the next form can even be compiled.
            if (&clojure::core::seq_QMARK_($form)) {
                my $af = &clojure::core::first($form);
                if (&clojure::core::symbol_QMARK_($af)) {
                    local $clojure::core::_AMPERSAND_env = +{};
                    my $ae = &clojure::core::macroexpand_1($form);
                    if (&clojure::core::list_QMARK_($ae)) {
                        my $aef = &clojure::core::first($ae);
                        if (&clojure::core::symbol_QMARK_($aef)) {
                            if ('do' eq &clojure::core::name($aef)) {
                                my $aer = &clojure::core::rest($ae);
                                @forms = @{&clojure::core::_perl_array($aer)};
                            }
                        }
                    }
                }
            }
            for my $form1 (@forms) {
                eval {
                    $a = &{$eval_override}($form1);
                };
                if ($@) {
                    die "Problem in: $filename_for_citation: ".clojure::core::pr_str($@);
                }
            }
        }
        $stuf = substr($stuf, length($r->{'text'}));
    }
    return $a;
}

# Was not compiling ... gen-class ... open file; start writing Perl for each eval
# Was compiling ... gen-class changes nothing
# End of file ... if this file owns the operative gen-class, close output file
# Nested require ... continue writing / not writing to the same file

our $SIGNATURE = '# Generated by' # cloak a likely cloc --exclude-content= pattern
    . ' Pajaro';

_intern('clojure.core','gen-class',
        sub {
            my @xs = @_;
            my $dqname = clojure::core::deref($clojure::core::_STAR_ns_STAR_)->get_name();
            my $ext='pl';
            for my ($k,$v) (@xs) {
                if ('name' eq clojure::core::name($k)) {
                    $dqname=$v;
                }
                elsif ('ext' eq clojure::core::name($k)) {
                    $ext=$v;
                }
                else {
                    die "gen-class does not handle ".clojure::core::pr_str($k)."\n";
                }
            }
            # If not *compile-files*, skip
            # If already writing, skip
            # Open file & set COMPILE_TO_FILEHANDLE
            #   whose dynamic scope is controlled by -eval-file
            if (clojure::core::deref($clojure::core::_STAR_compile_files_STAR_)) {
                if (! $COMPILE_TO_FILEHANDLE) {
                    my $sep = File::Spec->catfile('','');
                    my $root = clojure::core::deref($clojure::core::_STAR_compile_path_STAR_);
		    my $relativefilename = $dqname;
		    $relativefilename =~ s,[.],$sep,g;
		    my $plfilename=$root.$sep.$relativefilename
			. '.cljpl.'
			. $ext;

		    if (1 || clojure::core::deref($clojure::core::_STAR_verbose_STAR_)) {
			print STDERR "Compiling to $plfilename\n";
		    }

		    $COMPILE_TO_FILEHANDLE = new FileHandle;
		    my $dir = dirname($plfilename);
		    if ($dir) {
			File::Path::make_path($dir);
		    }
		    $COMPILE_TO_FILEHANDLE->open($plfilename, '>') || die "Unable to open $plfilename for output";
		    print $COMPILE_TO_FILEHANDLE "$SIGNATURE\n";
		    if ('pl' eq $ext) {
			# Preamble for AOT-compiled .pl file:
			print $COMPILE_TO_FILEHANDLE "use Pajaro;\n";
			# Forms of this file that ran before gen-class, e.g. the rest of ns:
			print $COMPILE_TO_FILEHANDLE "$_;\n" for @{$FILE_PERL // []};
		    }
		}
	    }
	    undef;
	});

_intern('clojure.core','-eval-file',
        sub {
            my $filename = shift; # complete filename

	    my $previousOutputFile = $COMPILE_TO_FILEHANDLE;
	    local $COMPILE_TO_FILEHANDLE = $previousOutputFile;
	    local $FILE_PERL = clojure::core::deref($clojure::core::_STAR_compile_files_STAR_) ? [] : undef;

	    # Read entire file (as UTF-8, so string literals hold code points,
	    # not bytes -- e.g. (count "Где") must be 3, not 6)
	    open(H,'<:encoding(UTF-8)',$filename) || die "Can't read file: $filename";
	    my $stuf = <H>;
	    # Treat leading #! (shell bang) as a comment on 1st line only:
	    if ($stuf =~ /^#!/) {
		$stuf = '';
	    }
	    while (<H>) {
		$stuf .= $_;
	    }
	    close(H);
	    _eval_multi_line_string($filename, $stuf);
	    if ($COMPILE_TO_FILEHANDLE && !$previousOutputFile) {
		print $COMPILE_TO_FILEHANDLE ";\n1; # require FILENAME demands a true value at the end\n";
		close($COMPILE_TO_FILEHANDLE);
		if (clojure::core::deref($clojure::core::_STAR_verbose_STAR_)) {
		    print STDERR "Finished Compiling to File\n";
		}
	    }
        });

# filename consisting of search-path directory + relative name + discovered extension
# returns undef if nothing found
sub _find_on_path {
    my $exts = shift; # ARRAY of undotted filename extension in order of priority
    my $dirs = shift; # ARRAY of directories in order of priority. (Without any trailing dir separator)
    my $relative=shift; # relative filename with OS-appropriate separators
    my $loud = shift; # true to show a not-found message
    my @tried;
    for my $ext (@$exts) {
	for my $dir (@$dirs) {
	    if ($dir =~ m,^~/,) {
		$dir =~ s,^~,$ENV{HOME},;
	    }
	    my $dir2 = $dir; $dir2 =~ s,/$,,;
	    my $probe = "${dir2}/${relative}.${ext}";
	    push @tried, $probe;
	    if ( -f $probe ) {
		return $probe;
	    }
	}
    }
    if ($loud) {
	print STDERR "Not found: any of ".join(', ',@tried)."\n";
    }
    undef
}

# Composes filenames relative to the current working directory.
_intern('clojure.core','load',
        sub {
            my $s = shift; # (classpath-relative) STRING with DIRECTORY SLASHES and NO FILENAME EXTENSION
	    $s =~ s,^/,,; # remove initial leading slash if any
	    die "Whoops, does $s already contain an extension?" if ($s =~ /cljpl/);
            my $packaging = shift; # pl or pm
            $packaging = 'pm' unless defined($packaging);
	    die "Packaging must be pl or pm"
		unless ('pl' eq $packaging
			|| 'pm' eq $packaging);
	    my $loud = 0;
	    # Two directory searches:
	    # (1) source file A.cljpl, A.cljc, A.clj
	    # (2) compiled file A.cljpl.pm, A.cljpl.pl
	    # Search in *path* followed by (the string, not CODE, members of) @INC
	    my @dirs = grep(length,(split(/:/,clojure::core::deref($clojure::core::_STAR_path_STAR_))));
	    push(@dirs, grep(!ref,@INC));
	    my $srcFile = _find_on_path(+['cljpl','cljc','clj'], \@dirs, $s, $loud);
	    if (!$srcFile) {
		die "Required file not found: $s";
	    }
	    # Look for AOT-compiled file, _unless_ --compile is in force
	    my $compiledFile;
	    if (!clojure::core::deref($clojure::core::_STAR_compile_files_STAR_)) {
		$compiledFile = _find_on_path(+["cljpl.${packaging}"], \@dirs, $s, $loud);
	    }
	    # disregard compiledFile if src is newer; a woefully incomplete criterion
	    if ($compiledFile && -f $compiledFile) {
                my @stat = stat($srcFile);
                my @plstat = stat($compiledFile);
                my $mtime = $stat[9];
                my $plmtime = $plstat[9];
                if ($plmtime <= $mtime) {
                    undef $compiledFile;
                }
	    }

	    # Allow eval-file to change *ns*, but change it back:
	    local $$clojure::core::_STAR_ns_STAR_[Pajaro::Var::VAR_REFERENT_SLOT] =
		$$clojure::core::_STAR_ns_STAR_[Pajaro::Var::VAR_REFERENT_SLOT];

	    # Rerun AOT-compiled Perl or interpret the source:
	    if ($compiledFile) {
		CORE::require $compiledFile;
	    }
	    else {
		&clojure::core::_eval_file($srcFile);
	    }

            undef
        });

###--- Higher-order access to Perl builtins

_intern('clojure.core', 'perl-sort',
      sub {
          my $comparator = shift; # required!
          my $perl_coll = shift;
          return +[ CORE::sort {my $aa=$a; my $bb=$b; &$comparator($aa,$bb)} @{$perl_coll} ];
	});

###--- Hand off to the Clojure portion of clojure.core

_freshen_global_hierarchy();

clojure::core::load('clojure/core');

1;
