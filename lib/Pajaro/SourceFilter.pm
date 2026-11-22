# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

package Pajaro::SourceFilter;

=pod
After the Perl statement C<use Pajaro::SourceFilter;>, the
remainder of the file is processed as Pajaro (Clojure-ish) code.
It is read as UTF-8.

A common preamble uses FindBin and SourceFilter:

 #!/usr/bin/perl
 ;;# -*- mode: clojure -*-
 ;;use FindBin qw($RealBin);
 ;;use lib "$RealBin/lib";
 ;;use lib "$RealBin/my_program_lib"; # for your "use'd" .pm and "require'd" .clj files 
 ;;use Pajaro::SourceFilter;

It is an acrobatic maneuver coordinating a command shell, Perl, Emacs Clojure Mode, and Pajaro/Clojure.

1. The first line is intended for a command shell. Perl and Clojure regard it as a comment.
2. The second line is intended for Emacs. Perl sees it as two empty statements plus a comment. Clojure sees it as a comment.
3. The third, fourth, and fifth lines (C<use FindBin>, C<use lib>, C<use Pajaro::SourceFilter>) are intended for Perl. They load Pajaro and imply that the rest of the file is for Clojure.

Guarding the Perl directives as Clojure comments avoids conflicts with Emacs Clojure formatting and Paredit, which expect the whole buffer to be in Clojure.

=cut

use Filter::Util::Call;
use Pajaro;

sub import
{
    my($type, @arguments) = @_ ;
    
    filter_add(
	sub 
	{
	    my $filename = (caller)[1];
	    my $status;
	    while ( ($status=filter_read()) > 0 ) {
		;
	    }
	    if (0==$status) {
		# Perl hands the filter raw bytes; decode like require'd files (read as UTF-8)
		utf8::decode($_);
		# End of input. Evaluate (run) it:
		Pajaro::_eval_multi_line_string($filename, $_);
		# We executed it already, so nothing is left for Perl:
		$_ = "1;\n";
	    }
	    $status;
	} )
}

1;
