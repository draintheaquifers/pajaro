# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

package Pajaro::Hierarchy;
our @ISA=();
use List::Util (uniq);

=head1 DESCRIPTION

Clojure-ish hierarchy implementation in which each node is a String

=head2 new()

New empty hierarchy.

=cut

sub new {
    my $class = shift;
    my $this = +{'CHILDREN'=>{}, 'PARENTS'=>{}};
    return bless $this, $class;
}

=head2 h->_encode(key)

Callback that processes a key before insertion into the hierarchy's
internal data structure.

=cut

sub _encode {
    my $this = shift;
    my $x = shift;
    $x;
}

=head2 h->_decode(key)

Callback that processes a key after extraction from the hierarchy's
internal data structure on its way back to the client.

=cut

sub _decode {
    my $this = shift;
    my $x = shift;
    $x;
}

=head2 h->_derivations()

Array of child, parent

=cut

sub _derivations {
    my $this = shift;
    my @ret;
    for my $tag (keys(%{$$this{'PARENTS'}})) {
	for my $parent (keys(%{$$this{'PARENTS'}{$tag}})) {
	    push(@ret, +[$this->_decode($tag), $this->_decode($parent)]);
	}
    }
    return +[@ret];
}

=head2 h->_derive( CHILD, PARENT )

Records a child-parent relationship.

=cut

sub _derive {
    my $this = shift;
    my $tag = shift;
    my $parent = shift;
    $tag = $this->_encode($tag);
    $parent = $this->_encode($parent);
    $$this{'CHILDREN'}{$parent}{$tag}=$tag;
    $$this{'PARENTS'}{$tag}{$parent}=$parent;
    return $this;
}

=head2 h->_underive( CHILD, PARENT )

Removes a child-parent relationship, if it was present.

=cut

sub _underive {
    my $this = shift;
    my $tag = shift;
    my $parent = shift;
    $tag = $this->_encode($tag);
    $parent = $this->encode($parent);
    delete $$this{'CHILDREN'}{$parent}{$tag};
    delete $$this{'PARENTS'}{$tag}{$parent};
    return $this;
}

sub _walk {
    my $this = shift;
    my $k = shift;
    my $tag = shift;
    my @todo = ($tag);
    my @ret;
    my %ret; # duplicate for content checking
    while (@todo) {
	my ($tag1) = @todo;
	# add 1st todo (i.e., tag) to the result
	# add all children/parents of tag to the todo list
	#   except those which are already done
	push(@ret, $tag1);
	$ret{$tag1}=1;
	my @next = sort(keys(%{$$this{$k}{$tag1}}));
	my @todo0 = uniq(@todo,@next);
	@todo = grep(!exists($ret{$_}), @todo0);
    }
    @ret = grep($_ ne $tag, @ret);
    return \@ret;
}

=head2 h->_ancestors( CHILD )

Perl array of the given node's parent, grandparent, etc., or
an empty list if the given node is not in the hierarchy
or has no parent.

=cut

sub _ancestors {
    my $this = shift;
    my $tag = shift;
    $tag = $this->_encode($tag);
    return +[map($this->_decode($_), @{_walk($this, 'PARENTS', $tag)})];
}

=head2 h->_descendants( PARENT )

Perl array of the given node's children, grandchildren, etc., or
an empty list if the given node is not in the hierarchy
or has no child.

=cut

sub _descendants {
    my $this = shift;
    my $tag = shift;
    $tag = $this->_encode($tag);
    return +[map($this->_decode($_), @{_walk($this, 'CHILDREN', $tag)})];
}

1;
