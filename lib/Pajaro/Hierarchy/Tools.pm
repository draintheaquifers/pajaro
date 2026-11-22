# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

package Pajaro::Hierarchy::Tools;

use Scalar::Util qw'blessed';

no strict 'refs';

use Pajaro::Hierarchy;

=head1 DESCRIPTION

Applications of hierarchies

=head2 all_perl_packages

Array of Perl packages, e.g., Pajaro::Hierarchy and UNIVERSAL.

=cut

sub all_perl_packages {
    my @todo = qw(::);
    my @ret;
    while (@todo) {
	my $p = shift(@todo);
	next if ($p eq '::main::'); # cycle: main=>(root)
	push(@ret, $p);
	my @subpkgs = grep($_ =~ /::$/, (keys %{$p}));
	@todo = (@todo, map("${p}${_}", @subpkgs));
    }
    # Strip the :: prefix and suffix from each package
    return map(substr($_,2,-2), @ret);
}

sub all_perl_oo_packages {
    my @pp = all_perl_packages();
    my @oo = grep (&{sub{
	# is there @{$_::ISA}?
	my $probe = "${_}::ISA";
        exists(${"${_}::"}{'ISA'})
		       }}, @pp);
    return @oo;
	}

=head2 perl_hierarchy( EMPTY-HIERARCHY )

Hierarchy reflecting Perl packages' C<@ISA> arrays.

=cut

sub perl_hierarchy { # Everything derives from UNIVERSAL
    #my $encoder = shift;
    my $h = shift; #new Pajaro::Hierarchy();
    my @a = all_perl_oo_packages();
    for my $p (@a) {
	my $pe = $p; # &$encoder($p);
	if (exists(${"${p}::"}{ISA})) {
	    for my $i (@{${"${p}::"}{ISA}}) {
		$h->_derive($pe, $i);
	    }
	    $h->_derive($pe, UNIVERSAL::);
	}
    }
    return $h;
}

#sub merged_global_hierarchy {
#    my $custom = shift;
#    my $encoder = shift;
#    my $ret = new Pajaro::Hierarchy();
#    $ret->_copy_from(perl_hierarchy($encoder));
#    $ret->_copy_from($custom);
#    return $ret;
#}

1;
