# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

# Munging table adapted for Pajaro from ClojureScript

package Pajaro::Munge;

=head1 DESCRIPTION

Translates Clojure symbols to Perl identifiers

=cut

use Exporter 'import';

our @EXPORT_OK = qw(munge keyword_munge);   # exported automatically

## Munge Clojure identifiers to Perl / demunge Perl to Clojure:
use feature 'state';

our %MUNGE_MAP = ( # core.cljs l.377
    '-' =>    '_',
    ':' =>    '_COLON_',
    '+' =>    '_PLUS_',
    '>' =>    '_GT_',
    '<' =>    '_LT_',
    '=' =>    '_EQ_',
    '~' =>    '_TILDE_',
    '!' =>    '_BANG_',
    '@' =>    '_CIRCA_',
    '#' =>    '_SHARP_',
    "'" =>    '_SINGLEQUOTE_',
    "\\\"" => '_DOUBLEQUOTE_',
    '%' =>    '_PERCENT_',
    '^' =>    '_CARET_',
    '&' =>    '_AMPERSAND_',
    '*' =>    '_STAR_',
    '|' =>    '_BAR_',
    '{' =>    '_LBRACE_',
    '}' =>    '_RBRACE_',
    '[' =>    '_LBRACK_',
    ']' =>    '_RBRACK_',
    '/' =>    '_SLASH_',
    "\\\\" => '_BSLASH_',
    '?' =>    '_QMARK_');

our %KEYWORD_MUNGE_MAP = %MUNGE_MAP;
$KEYWORD_MUNGE_MAP{'-'}='_DASH_';

=head2 munge

Replaces Clojure-only symbol characters to a mnemonic that is legal in
Perl identifiers. The parameter should be a string representing 1
Clojure identifier - not ns-qualified with C</> nor package-qualified
with C<.>.  Munge each namespace segment separately.

=cut

sub munge {
    my $u = shift;
    my $m = "$u";
    if ($m eq '_') {
        $m = '_UNDERBAR_';
    }
    elsif ($m eq '-') {
        $m = '_DASH_';
    }
    elsif ($m eq '.') {
	$m = '_DOT_';
    }
    else {
        for (my $i = length($m)-1; $i >= 0; $i--) {
            my $c = substr($m, $i, 1);
            if (exists($MUNGE_MAP{$c})) {
                $m = substr($m, 0, $i) . $MUNGE_MAP{$c} . substr($m, $i+1);
            }
        }
    }
    return $m;
}

=pod

keyword_munge is like munge, but preserves the difference
between hyphen and underscore

=cut

sub keyword_munge {
    my $u = shift;
    my $m = "$u";
    if ($m eq '_') {
        $m = '_UNDERBAR_';
    }
    elsif ($m eq '-') {
        $m = '_DASH_';
    }
    elsif ($m eq '.') {
	$m = '_DOT_';
    }
    else {
        for (my $i = length($m)-1; $i >= 0; $i--) {
            my $c = substr($m, $i, 1);
            if (exists($KEYWORD_MUNGE_MAP{$c})) {
                $m = substr($m, 0, $i) . $KEYWORD_MUNGE_MAP{$c} . substr($m, $i+1);
            }
        }
    }
    return $m;
}

1;
