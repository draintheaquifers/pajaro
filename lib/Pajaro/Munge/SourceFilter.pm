# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

package Pajaro::Munge::SourceFilter;

=head1 DESCRIPTION

Translates single-quoted Clojure symbols to Perl in these contexts:

=over

=item Sub declaration

 sub 'foo-baz?' {     ==>   sub foo_baz_QMARK_ {

=item Sub invocation

 &'foo-baz?'      ==>   &foo_baz_QMARK_

=back

=cut

use Filter::Util::Call;
use Pajaro::Munge qw(munge);

sub import {
   my ($type) = @_;
   my ($ref) = [];
   filter_add(bless $ref);
}

sub filter {
   my ($self) = @_;
   my ($status);
   s/(sub +|&)'([^']+)'/($1).(munge($2))/eg
      if ($status = filter_read()) > 0;
   $status;
}

1;
