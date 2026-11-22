# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

package Pajaro::Reader;

use experimental 'builtin';
use strict;
use warnings;
no warnings 'experimental::builtin';
use Data::Dumper qw(Dumper);

our $VERBOSE = 0;
our $VERBOSE_CHAR = 0;

our $NIL = undef;
our $NOTHING = bless +{}, 'Pajaro::Reader::Nothing';
sub nothing_QMARK_ {
        my $x = shift;
        return ref($x) eq 'Pajaro::Reader::Nothing';
}

our $QUOTE_SYM = clojure::core::symbol('quote');
our $DEREF_SYM = clojure::core::symbol('clojure.core','deref');
our $CONCAT1_SYM = clojure::core::symbol('clojure.core','concat1'); # eager concat
our $LIST_SYM = clojure::core::symbol('clojure.core','list');
our $SEQ_SYM = clojure::core::symbol('clojure.core','seq');
our $DOT_SYM = clojure::core::symbol('.');
our $NEW_SYM = clojure::core::symbol('new');
our $VAR_SYM = clojure::core::symbol('var');
our $FN_SYM = clojure::core::symbol('fn');
our $APPLY_SYM = clojure::core::symbol('clojure.core','apply');
our $VECTOR_SYM = clojure::core::symbol('clojure.core','vector');

### Cursor

use constant { CURSOR_TEXT=>0};
use constant { CURSOR_I=>1};
use constant { CURSOR_LINE=>2};
use constant { CURSOR_COL=>3};
use constant { CURSOR_INITLINE=>4};
use constant { CURSOR_INITCOL=>5};
use constant { CURSOR_EOF=>6};
use constant { CURSOR_PUTBACK=>7};

sub cursor { # text, {LINE=>, COL=>}?
    my $text = shift;
    my $init = shift;
    my $initline = $$init{'LINE'} ? $$init{'LINE'} : 0;
    my $initcol = $$init{'COL'} ? $$init{'COL'} : 0;
    return +[$text, 0, $initline, $initcol,
             $initline,$initcol];
}
sub cursor_context {
    my $cursor = shift;
    my $n = 25;
    my $marker = '|';
    my $atleft = $$cursor[CURSOR_I] >= $n ? $n : $$cursor[CURSOR_I];
    return "l.$$cursor[CURSOR_LINE]c.$$cursor[CURSOR_COL]: "
        .substr($$cursor[CURSOR_TEXT],$$cursor[CURSOR_I]-$atleft,$atleft)
        .$marker.substr($$cursor[CURSOR_TEXT],$$cursor[CURSOR_I],$n);
}

# Merges overlay_opts into opts. Overlay INDENT defaults to 2 addtl spaces.
sub push_opts {
    my $opts = shift;
    my $overlay_opts = shift;
    if (!$$overlay_opts{'INDENT'}) {
        $$overlay_opts{'INDENT'}="$$opts{'INDENT'}  ";
    }
    my %m = (%{$opts},%{$overlay_opts});
    return \%m;
}

# returns 1 character, or \r\n (which is returned as \n only), or undef if there is nothing left to read
sub read_ch_BANG {
    my $opts = shift;
    my $cursor = shift;
    my $text = $$cursor[CURSOR_TEXT];
    $$cursor[CURSOR_PUTBACK]=+[$$cursor[CURSOR_I], $$cursor[CURSOR_LINE], $$cursor[CURSOR_COL]];
    my $i = $$cursor[CURSOR_I];
    my $ret;
    if ($i < length($text)) {
        $$cursor[CURSOR_I]++;
        my $ch = substr($$cursor[CURSOR_TEXT], $i, 1);
        if ($ch eq "\n") {
            $$cursor[CURSOR_LINE]++;
            $$cursor[CURSOR_COL]=0;
        }
        elsif ($ch eq "\r") {
            $i++;
            if (($i < length($text)) && (substr($$cursor[CURSOR_TEXT],$i,1) eq "\n")) {
                $$cursor[CURSOR_I]++; # again
                $$cursor[CURSOR_LINE]++;
                $$cursor[CURSOR_COL]=0;
                $ch = "\n";
            }
        }
        else {
            $$cursor[CURSOR_COL]++;
        }
        $ret = $ch;
    }
    else {
        $$cursor[CURSOR_EOF]=1;
        $ret = undef;
    }
    #if ($VERBOSE_CHAR) { print STDERR "read_ch: returning '$ret': ".cursor_context($cursor)."\n"; }
    return $ret;
}
sub putback_ch_BANG {
    my $opts = shift;
    my $cursor = shift;
    if ($$cursor[CURSOR_PUTBACK]) {
        $$cursor[CURSOR_I]=$$cursor[CURSOR_PUTBACK]->[0];
        $$cursor[CURSOR_LINE]=$$cursor[CURSOR_PUTBACK]->[1];
        $$cursor[CURSOR_COL]=$$cursor[CURSOR_PUTBACK]->[2];
        delete $$cursor[CURSOR_PUTBACK];
    }
    else {
        die "Excessive putback";
    }
    #if($VERBOSE_CHAR) { print STDERR "putback: ".cursor_context($cursor)."\n"; }
    return undef;
}

sub skip_space_BANG {
    my $opts = shift;
    my $cursor = shift;
    for (;;) {
        my $ch = read_ch_BANG($opts, $cursor);
        last if (!defined($ch));
        if ($ch eq ';') {
            skip_thru_eol_BANG($opts, $cursor);
        }
        elsif (!($ch =~ /\s/ || $ch eq ' ' || $ch eq ',' || $ch eq "\n" || $ch eq "\t")) {
            putback_ch_BANG($opts, $cursor);
            last;
        }
    }
    #if ($VERBOSE_CHAR) { print STDERR "skip_space: ".cursor_context($cursor)."\n"; }
    return undef;
}
our $_SPLICE_KW = "Pajaro::Reader::Splice";
sub read_form_BANG { # returns $NOTHING if nothing could be read
    my $opts = shift;
    my $cursor = shift;
    my $ret = $NOTHING;
    my $position_memo;
    my $nested_opts = push_opts($opts);
    for (;;) { # repeat til reading an unskipped form
        skip_space_BANG($nested_opts, $cursor);
        $position_memo = +{
            'LINE', $$cursor[CURSOR_LINE],
            'COL', $$cursor[CURSOR_COL],
            'FILE', $$opts{'init-cursor'}{'FILE'}};
        #if ($VERBOSE) { print STDERR "$$opts{'INDENT'}read_form IN: ".caper::core::pr_str(cursor_context($cursor)).' opts:'.caper::core::pr_str($opts)."\n"; }
        my $ch = read_ch_BANG($nested_opts, $cursor);
        if (!defined($ch)) {
            if (nothing_QMARK_($ret)) {
                last
            }
            else {
                die 'EOF'
            }
        }
        elsif ($ch eq '\\') { # character-literal-outside-string
            putback_ch_BANG($nested_opts, $cursor);
	    $ret = read_character_BANG($nested_opts, $cursor);
            if (nothing_QMARK_($ret)) {
                die 'EOF'
            }
        }
        elsif ($ch eq '"') {
            putback_ch_BANG($nested_opts, $cursor);
            $ret = read_string_BANG($nested_opts, $cursor);
        }
        elsif ($ch eq '(') {
            putback_ch_BANG($nested_opts, $cursor);
            $ret = read_list_BANG($nested_opts, $cursor);
        }
        elsif ($ch eq '[') {
            putback_ch_BANG($nested_opts, $cursor);
            $ret = read_vector_BANG($nested_opts, $cursor);
        }
        elsif ($ch eq '{') {
            putback_ch_BANG($nested_opts, $cursor);
            $ret = read_map_BANG($nested_opts, $cursor);
        }

        elsif ($ch eq ')') {
            putback_ch_BANG($nested_opts, $cursor);
            die "Lost something" unless nothing_QMARK_($ret);
            last;
        }
        elsif ($ch eq ']') {
            putback_ch_BANG($nested_opts, $cursor);
            die "Lost something" unless nothing_QMARK_($ret);
            last;
        }
        elsif ($ch eq '}') {
            putback_ch_BANG($nested_opts, $cursor);
            die "Lost something" unless nothing_QMARK_($ret);
            last;
        }
        elsif ($ch eq '#') {
            $ret = read_readermacro_BANG($nested_opts, $cursor);
        }
        elsif ($ch eq "'") {
            skip_space_BANG($nested_opts, $cursor);
            my $body = read_form_BANG($nested_opts, $cursor);
            if (nothing_QMARK_($body)) { die 'EOF'; }
            if ($$opts{'SQUOTE'}) {
                $ret = clojure::core::list
                    ($CONCAT1_SYM,
                     clojure::core::list($LIST_SYM, clojure::core::list($QUOTE_SYM, $QUOTE_SYM)),
                     clojure::core::list($LIST_SYM, $body));
            }
            else {
                $ret = clojure::core::list($QUOTE_SYM, $body);
            }
        }
        elsif ($ch eq '@') {
            skip_space_BANG($nested_opts, $cursor);
            my $body = read_form_BANG($nested_opts, $cursor);
            if (nothing_QMARK_($body)) { die 'EOF'; }
            ## In syntax quote, strip '(quote ...) from body and reapply it to our result
            if ($$opts{'SQUOTE'}) {
                if (clojure::core::list_QMARK_($body)) {
                    $body = clojure::core::first(clojure::core::rest($body));
                }
                else {
                    die("Not a list ".clojure::core::pr_str($body)." rather ".ref($body));
                }
                $ret = clojure::core::list($QUOTE_SYM, clojure::core::list($DEREF_SYM, $body));
            }
            else {
                $ret = clojure::core::list($DEREF_SYM, $body);
            }
        }
        elsif ($ch eq '^') {
            # expect map or tag-symbol
            my $meta_raw = read_form_BANG($nested_opts, $cursor);
            if (nothing_QMARK_($meta_raw)) { die 'EOF'; }
            my $meta = (ref($meta_raw) eq 'Pajaro::COWMap')
                ? $meta_raw
                : ((ref($meta_raw) eq 'Pajaro::Keyword') ? clojure::core::hash_map($meta_raw, builtin::true)
		   : clojure::core::hash_map(clojure::core::keyword('tag'),$meta_raw));
            skip_space_BANG($nested_opts, $cursor);
            my $thing = read_form_BANG($nested_opts, $cursor);
            if (nothing_QMARK_($thing)) { die 'EOF'; }
            $ret = clojure::core::vary_meta($thing,
                                   \&clojure::core::merge,
                                   $meta);
        }
        ##   ` -> read next form & embed in (clojure.core/quote
        ##           and recurse in an abstruse mode
        ##           that rewrites collection literals and recognizes unquotes
        ## see reader.clj l.696, syntax-quote*
        elsif ($ch eq '`') {
            die 'Do not nest syntax quote' if $$nested_opts{'SQUOTE'};
            skip_space_BANG($nested_opts, $cursor);
            $$nested_opts{'SQUOTE'}=+{}; # dictionary of sym# to generated name
            my $unquote = $$nested_opts{'UNQUOTE'};
            delete $$nested_opts{'UNQUOTE'};
            $ret = read_form_BANG($nested_opts, $cursor);
            if (nothing_QMARK_($ret)) { die 'EOF'; }
            $$nested_opts{'UNQUOTE'}=$unquote;
            delete $$nested_opts{'SQUOTE'};
        }
        elsif ($ch eq '~') {
            die 'Unquote outside syntax quote' unless $$nested_opts{'SQUOTE'};
            die 'Do not nest Unquote' if $$nested_opts{'UNQUOTE'};
            skip_space_BANG($nested_opts, $cursor);
            my $ch2 = read_ch_BANG($nested_opts, $cursor);
            if ($ch2 eq '@') {# unquote-splicing...
                my $squote = $$nested_opts{'SQUOTE'};
                delete $$nested_opts{'SQUOTE'};
                $$nested_opts{'UNQUOTE'}=1;
                my $body = read_form_BANG($nested_opts, $cursor);
                if (nothing_QMARK_($body)) { die 'EOF'; }
                $ret = &clojure::core::vary_meta
                    ($body,
                     \&clojure::core::assoc,
                     $_SPLICE_KW,
                     builtin::true);
                $$nested_opts{'SQUOTE'}=$squote;
                delete $$nested_opts{'UNQUOTE'};
            }
            else {
                putback_ch_BANG($nested_opts, $cursor);
                my $squote = $$nested_opts{'SQUOTE'};
                delete $$nested_opts{'SQUOTE'};
                $$nested_opts{'UNQUOTE'}=1;
                $ret = read_form_BANG($nested_opts, $cursor);
                if (nothing_QMARK_($ret)) { die 'EOF'; }
                $$nested_opts{'SQUOTE'}=$squote;
                delete $$nested_opts{'UNQUOTE'};
            }
        }
        else {
            #if ($VERBOSE_CHAR) { print STDERR "$$opts{'INDENT'}Read the character <$ch> and by default assume to read a symbol or keyword or number...\n"; }
            putback_ch_BANG($nested_opts, $cursor);
            $ret = read_word_BANG($nested_opts, $cursor);
        }
        if (!nothing_QMARK_($ret) || $$cursor[CURSOR_EOF]) {
            last;
        }
    }
    #if ($VERBOSE) { print STDERR "$$opts{'INDENT'}read_form OUT: ".cursor_context($cursor)."\n"; }
    if (1 || !( $$opts{'INDENT'})) { # save time by attaching position meta to outermost form only
        if (clojure::core::satisfies_QMARK_($clojure::core::IWithMeta,$ret)) {
            $ret = clojure::core::vary_meta($ret, \&clojure::core::assoc,
                                   $Pajaro::KW_FILE, $$position_memo{'FILE'},
                                   $Pajaro::KW_LINE, $$position_memo{'LINE'},
                                   $Pajaro::KW_COL, $$position_memo{'COL'});
        }
    }
    #if ($VERBOSE) {
    #    if (defined($ret)) {
    #        print STDERR "$$opts{'INDENT'}read form: $ret [".(caper::core::_type_perl($ret)).']'.caper::core::pr_str($ret)."\n"; }
    #    else {
    #        print STDERR "$$opts{'INDENT'}read form: <undef>\n";
    #    }
   # }
    return $ret;
}

sub read_forms_BANG {
    my $opts = shift;
    my $cursor = shift;
    my $closer = shift;
    my @body;
    my $orig_env = +{%{$$opts{'ENV'}}};
    my $scrape_vector = '';
    # read one form after another until closing delimiter
    for (;;) {
        skip_space_BANG($opts, $cursor);
        my $ch = read_ch_BANG($opts, $cursor);
        if (!defined($ch)) {die 'EOF';}
        elsif ($closer eq $ch) {
            last;
        }
        else {
            putback_ch_BANG($opts, $cursor);
            #if ($VERBOSE_CHAR) { print STDERR "<$ch> is Not the expected form-ending $closer, so I put it back\n"; }
            my $form = read_form_BANG($opts, $cursor);
            if (nothing_QMARK_($form)) { #print STDERR "Nothing; next...\n";
                                         next; }
            #if (!defined($form)) { die 'EOF'; }
            push(@body, $form);
            if (')' eq $closer
                && 1==@body
                && clojure::core::simple_symbol_QMARK_($body[0])
                && ((clojure::core::name($body[0]) eq 'defmacro')
                    || (clojure::core::name($body[0]) eq 'fn*'))) {
                $scrape_vector='arglist'; # defmacro, fn*
            }
            elsif (')' eq $closer
                   && 1==@body
                   && clojure::core::simple_symbol_QMARK_($body[0])
                   && (clojure::core::name($body[0]) eq 'let*'
                       || clojure::core::name($body[0]) eq 'letfn*')) {
                $scrape_vector='bindings'; # let*, letfn*
            }

            if ($scrape_vector eq 'arglist'
                && 'Pajaro::COWVector' eq ref($body[$#body])) {
                for (my $s=clojure::core::seq($body[$#body]); $s; $s=&clojure::core::next($s)) {
                    my $argsymbol = clojure::core::first($s);
                    my $k=clojure::core::name($argsymbol);
                    $$opts{'ENV'}{$k}=$argsymbol;
                }
                $scrape_vector='';
            }
            elsif ($scrape_vector eq 'bindings' && 'Pajaro::COWVector' eq ref($body[$#body])) {
                for (my $s=clojure::core::seq($body[$#body]); $s; $s=&clojure::core::next(clojure::core::rest($s))) {
                    my $localsymbol=clojure::core::first($s);
                    my $k=clojure::core::name($localsymbol);
                    $$opts{'ENV'}{$k}=$localsymbol;
                }
                $scrape_vector='';
            }
            elsif ($scrape_vector eq 'bindings-with-destructuring'
                   && 'Pajaro::COWVector' eq ref($body[$#body])) {
                if ($clojure::core::destructure) {
                    my $destructured = &clojure::core::destructure($body[$#body]);
                    for (my $s=clojure::core::seq($destructured); $s; $s=&clojure::core::next(clojure::core::rest($s))) {
                        my $localsymbol=clojure::core::first($s);
                        my $k=clojure::core::name($localsymbol);
                        $$opts{'ENV'}{$k}=$localsymbol;
                    }
                }
                else
                {
                    for (my $s=clojure::core::seq($body[$#body]); $s; $s=&clojure::core::next(clojure::core::rest($s))) {
                        my $localsymbol=clojure::core::first($s);
                        my $k=clojure::core::name($localsymbol);
                        $$opts{'ENV'}{$k}=$localsymbol;
                    }
                }
                $scrape_vector='';
            }
        }
    }
    ## restore opts env if we pushed one
    $$opts{'ENV'}=$orig_env;
    return @body;
}

sub read_reader_conditional_forms_BANG {
    my $opts = shift;
    my $cursor = shift;
    my $closer = ')';
    my @body;
    my $scrape_vector = '';
    # read one form after another until closing delimiter
    my $ret = $NOTHING;
    my $ignoring_opts = push_opts($opts, +{'FOREIGN'=>1});
  OUTER:
    for (;;) {
	my $kw;
	for (;;) {
	    skip_space_BANG($opts, $cursor);
	    my $ch = read_ch_BANG($opts, $cursor);
	    if (!defined($ch)) {die 'EOF';}
	    elsif ($closer eq $ch) {
		last OUTER;
	    }
	    putback_ch_BANG($opts, $cursor);
	    $kw = read_form_BANG($opts, $cursor);
	    if (!nothing_QMARK_($kw)) {
		last;
	    }
	}
	if (!clojure::core::keyword_QMARK_($kw)) {
	    die "Expected reader-conditional selector keyword";
	}
	my $matters = nothing_QMARK_($ret)
	    && ($Pajaro::KW_PAJARO_CLJPL->_equiv($kw)    # 'cljpl' eq (clojure::core::name($kw))
		|| 'default' eq (clojure::core::name($kw)));
	my $form_opts = $matters ? $opts : $ignoring_opts;
	my $form;
	for (;;) {
	    skip_space_BANG($opts, $cursor);
            $form = read_form_BANG($form_opts, $cursor);
            if (!nothing_QMARK_($form)) {
		last;
	    }
	}
	if ($matters) {
	    $ret = $form;
	}
  }
    return $ret;
}

## The singular "read_...BANG" functions return 1 form read.
sub read_list_BANG {
    my $opts = shift;
    my $cursor = shift;
    my $ch = read_ch_BANG($opts, $cursor);
    die 'POINT d' unless $ch eq '(';
    my @body = read_forms_BANG($opts, $cursor, ')');
    my $ret;
    if ($$opts{'SQUOTE'}) {
        my @sqbody;
        push (@sqbody, $CONCAT1_SYM);
        for my $b (@body) {
            # wrap in ('list ...) unless marked as SPLICE
            if (clojure::core::get(clojure::core::meta($b), $_SPLICE_KW)) {
                push(@sqbody, $b);
            }
            else {
                push(@sqbody, clojure::core::list($LIST_SYM, $b));
            }
        }
        $ret=clojure::core::list($SEQ_SYM, clojure::core::list(@sqbody));
    }
    #elsif ($$opts{'UNQUOTE'}) {
    #    $ret = caper::core::list(caper::core::symbol('clojure.core','list'), @body); # ?
    #}
    else {
        # Flatten spliced sub-lists, e.g., from reader conditional #?@(...)
        for (my $i = $#body; $i >= 0; $i--) {
            if (clojure::core::get(clojure::core::meta($body[$i]), $_SPLICE_KW)) {
                splice(@body, $i, 1, @{$body[$i]->_perl_array()});
            }
        }
        $ret = clojure::core::list(@body);
    }
    return $ret;
}
## The singular "read_...BANG" functions return 1 form read.
sub read_reader_conditional_list_BANG { # like read_list_BANG_ but does not try to interpret the inapplicable clauses
    my $opts = shift;
    my $cursor = shift;
    my $ch = read_ch_BANG($opts, $cursor);
    die 'POINT d' unless $ch eq '(';
    my @body = read_reader_conditional_forms_BANG($opts, $cursor);
    return $body[0];
}
sub read_map_BANG {
    my $opts = shift;
    my $cursor = shift;
    my $ch = read_ch_BANG($opts, $cursor);
    if (!defined($ch)) {die 'EOF'}
    die 'POINT e' unless $ch eq '{';
    my @body = read_forms_BANG($opts, $cursor, '}');

    # Flatten spliced sub-lists, e.g., from reader conditional #?@(...)
    for (my $i = $#body; $i >= 0; $i--) {
        if (clojure::core::get(clojure::core::meta($body[$i]), $_SPLICE_KW)) {
            splice(@body, $i, 1, @{$body[$i]->_perl_array()});
        }
    }

    return clojure::core::hash_map(@body);
}
sub read_vector_BANG {
    my $opts = shift;
    my $cursor = shift;
    my $ch = read_ch_BANG($opts, $cursor);
    if (!defined($ch)) { die 'EOF' }
    die 'POINT f' unless $ch eq '[';
    my @body = read_forms_BANG($opts, $cursor, ']');
    my $ret;
    if ($$opts{'SQUOTE'}) {
        my @sqbody;
        push (@sqbody, $CONCAT1_SYM);
        for my $b (@body) {
            # wrap in ('list ...) unless marked as SPLICE
            if (clojure::core::get(clojure::core::meta($b), $_SPLICE_KW)) {
                push(@sqbody, $b);
            }
            else {
                push(@sqbody, clojure::core::list($LIST_SYM, $b));
            }
        }
        $ret=clojure::core::list($SEQ_SYM, clojure::core::list(@sqbody));
        $ret=clojure::core::list($APPLY_SYM, $VECTOR_SYM, $ret);
    }
    else {
        # Flatten spliced sub-lists, e.g., from reader conditional #?@(...)
        for (my $i = $#body; $i >= 0; $i--) {
            if (clojure::core::get(clojure::core::meta($body[$i]), $_SPLICE_KW)) {
                splice(@body, $i, 1, @{$body[$i]->_perl_array()});
            }
        }

        $ret = clojure::core::vector(@body);
    }
    return $ret;
}
sub read_set_BANG { # cursor is positioned after the octothorp
    my $opts = shift;
    my $cursor = shift;
    my $ch = read_ch_BANG($opts, $cursor);
    if (!defined($ch)) {die 'EOF'}
    die 'POINT g' unless $ch eq '{';
    my @body = read_forms_BANG($opts, $cursor, '}');

    # Flatten spliced sub-lists, e.g., from reader conditional #?@(...)
    for (my $i = $#body; $i >= 0; $i--) {
        if (clojure::core::get(clojure::core::meta($body[$i]), $_SPLICE_KW)) {
            splice(@body, $i, 1, @{$body[$i]->_perl_array()});
        }
    }

    return new Pajaro::COWSet(undef, @body);
}

our %STRING_ESCAPES = ('"'=>'"',
                       "'"=>"'",
                       'b'=>chr(8),
                       'f'=>chr(12),
                       'n'=>chr(10),
                       'r'=>chr(13),
                       't'=>chr(9),
                       '\\'=>'\\'
    );

sub read_string_BANG { # reads a string literal from cursor. Do not confuse with the core fn read_string, which reads (anything) *from* a string
    my $opts = shift;
    my $cursor = shift;
    my $ch = read_ch_BANG($opts, $cursor);
    if(!defined($ch)) {die 'EOF'}
    die 'POINT h' unless $ch eq '"';
    my $body = '';
    for (;;) {
        $ch = read_ch_BANG($opts, $cursor);
        if (!defined($ch)) { die 'EOF'; }
        elsif ('\\' eq $ch) {
            $ch = read_ch_BANG($opts, $cursor);
            if (!defined($ch)) { die 'EOF'; }
            elsif (exists($STRING_ESCAPES{$ch})) { $body .= $STRING_ESCAPES{$ch}; }
            elsif ('u' eq $ch) {
                my $c1=read_ch_BANG($opts, $cursor);
                my $c2=read_ch_BANG($opts, $cursor);
                my $c3=read_ch_BANG($opts, $cursor);
                my $c4=read_ch_BANG($opts, $cursor);
                if (!defined($c4)) { die 'EOF' }
                my $hx = "$c1$c2$c3$c4";
                my $num = hex($hx);
                $body .= chr($num);
            }
            else {
                $body .= $ch;
            }
        }
        elsif ('"' eq $ch) {
            last;
        }
        else {
            $body .= $ch;
        }
    }
    #if ($VERBOSE) { print STDERR "read_string returned <$body>\n"; }
    return "$body";
}
sub read_regex_BANG {
    my $opts = shift;
    my $cursor = shift;
    my $ch = read_ch_BANG($opts, $cursor);
    if (!defined($ch)) {die 'EOF'}
    die 'POINT k' unless $ch eq '"';
    my $body='';
    for (;;) {
        $ch = read_ch_BANG($opts, $cursor);
        if (!defined($ch)) { die 'EOF'; }
        elsif ('\\' eq $ch) {
            $ch = read_ch_BANG($opts, $cursor);
            if (!defined($ch)) { die 'EOF'; }
            else {
                $body .= ("\\" . $ch);
            }
        }
        elsif ('"' eq $ch) {
            last;
        }
        else {
            $body .= $ch;
        }
    }
    if ($$opts{'FOREIGN'}) {
		return 7777;
    }
    else {
	return qr($body);
    }
}

our $gensym_counter = 0;

# Symbols that syntax-quote should not qualify with a namespace:
our %SPECIAL_FORM = ('deftype*'=>1, '.'=>1, 'if'=>1, 'quote'=>1, 'let*'=>1, 'letfn*'=>1, 'do'=>1, 'def'=>1, 'defonce'=>1, 'set!'=>1, 'fn*'=>1, 'loop'=>1, 'recur'=>1,
		     'throw'=>1, 'case*'=>1, 'var'=>1, 'binding*'=>1, 'perl-statement'=>1,
                     'perl-infix'=>1, 'perl-unary'=>1, 'try'=>1, 'catch'=>1, 'finally'=>1);

#\newline, \space, \tab, \formfeed, \backspace, and \return yield the corresponding characters. Unicode characters are represented with \uNNNN as in Java. Octals are represented with \oNNN

our %CHAR_LITERAL_NAMES = (
    'newline'=>10,
    'space'=>32,
    'tab'=>9,
    'formfeed'=>12,
    'backspace'=>8,
    'return'=>13);

sub read_character_BANG { # character-literal-outside-string
    my $opts = shift;
    my $cursor = shift;
    {
	my $ch = read_ch_BANG($opts, $cursor);
	if ('\\' ne $ch) { die "Expected backslash" }
    }
    my $charname = '';
    for (;;) {
	my $ch = read_ch_BANG($opts, $cursor);
	if (!defined($ch)) { last }
	if (0==length($charname)) {
	    $charname = $ch;
	}
	else {
	    my $next_charname = "${charname}${ch}";
	    # \A and \z = start and end of the string, no wiggle room for linebreaks
	    if ($next_charname =~ /\A([a-z]+|u[0-9a-fA-F]{0,4}|o[0-7]{0,3})\z/) {
		$charname = $next_charname;
	    }
	    else {
		putback_ch_BANG($opts, $cursor);
		last;
	    }
	}
    }
    my $ret = '';
    if (1==length($charname)) {
	$ret=$charname;
    }
    elsif (exists($CHAR_LITERAL_NAMES{$charname})) {
	$ret=chr($CHAR_LITERAL_NAMES{$charname});
    }
    elsif ($charname =~ /^u([0-9a-fA-F]{4})$/) {
	$ret=chr(hex($1));
    }
    elsif ($charname =~ /^o([0-7]{3})$/) {
	$ret=chr(oct($1));
    }
    else {
	die "Unrecognized character name: '$charname'";
    }
    return $ret;
}

# Read a string that could be made into a keyword ns+name, symbol
# ns+name, tag for a tagged literal, etc. Die if the thing
# at the cursor isn't such an identifier.
sub read_symbol_name_BANG {
    my $opts = shift;
    my $cursor = shift;
    my $ret = '';
    for (;;) {
        my $ch = read_ch_BANG($opts, $cursor);
        if (!defined($ch)) {
            if ('' eq $ret) {
                $ret = $NOTHING;
            }
            last;
        }
        elsif ($ch =~ m,[-&/.:!'?<>=+%*a-zA-Z_0-9\$],) { # excludes '#'
            $ret .= $ch;
        }
        else {
            if ('' eq $ret) {
                die("The VERY FIRST character of supposedly a word is impossible:<$ch>\n");
            }
            putback_ch_BANG($opts, $cursor);
            last;
        }
    }
    if ($ret !~ m,^([^:0-9#/][^/]*)(?:/([^0-9][^/]*+))?$,
	&& $ret !~ /::/) {
	die "Not an id word: $ret"
    }
    return $ret
}

# Read keyword, symbol, boolean, nil, or number and decide what it is after isolating it. Returns $NOTHING if there is nothing to read. Returns undef for a positively read 'nil'.
sub read_word_BANG {
    my $opts = shift;
    my $cursor = shift;
    my $ret = '';
    for (;;) {
        my $ch = read_ch_BANG($opts, $cursor);
        if (!defined($ch)) {
            if ('' eq $ret) {
                $ret = $NOTHING;
            }
            last;
        }
        elsif ($ch =~ m,[-&#/.:!'?<>=+%*a-zA-Z_0-9\$],) {
            $ret .= $ch;
        }
        else {
            if ('' eq $ret) {
                die("The VERY FIRST character of supposedly a word is impossible:<$ch>\n");
            }
            putback_ch_BANG($opts, $cursor);
            last;
        }
    }
    # Number? Keyword? Symbol? Boolean? nil?
    if (defined($ret)) {
	if ($ret =~ m,(-?[0-9]+)/([0-9]+),) { # Ratio
	    my $numer = $1; my $denom = $2;
	    $ret = Math::BigRat->new($1,$2);
	    if (0 == $ret->numerator() || 1 == $ret->denominator()) {
		$ret = $ret->numerator();
	    }
        }
        elsif ($ret =~ /^(-)?0x([0-9a-fA-F]+)$/) { # Hex
	    if ($$opts{'FOREIGN'}) {
		$ret = 7777;
	    }
	    else {
		$ret = (($1 && ('-' eq $1)) ? -1 : 1) * hex($2)
	    }
        }
        elsif ($ret =~ /^(-)?2r([0-1]+)$/) { # Octal
	    if ($$opts{'FOREIGN'}) {
		$ret = 7777;
	    }
	    else {
		$ret = (($1 && ('-' eq $1)) ? -1 : 1) * oct("0b$2")
	    }
        }
        elsif ($ret ne '-' && $ret =~ /^[-0-9][0-9]*$/) { # integer (scalar or big)
	    if ($$opts{'FOREIGN'}) {
		$ret = 7778;
	    }
	    else {
		my $bi = Math::BigInt->new($ret);
		if ($bi >= $Pajaro::Long::MIN_VALUE
		    && $bi <= $Pajaro::Long::MAX_VALUE) {
		    $ret = CORE::int($bi->numify())
		}
		else {
		    $ret = $bi
		}
	    }
        }
        elsif ($ret ne '-' && $ret =~ /^([-0-9][0-9]*(?:[.][0-9]*)?)([Ee][-+]?[0-9]+|M|N)?$/) { # double (scalar or big)
	    if ($$opts{'FOREIGN'}) {
		$ret = 7778;
	    }
	    else {
		my $n=$1;
		my $e=$2;
		if (!defined($e)) {
		    $ret = Pajaro::_mk_double($ret);
		    #my $xx=$ret;
		    #print STDERR "Parsed Double:$xx ".Pajaro::_type_name($ret)."\n";
		}
		elsif ('N' eq $e) {
		    $ret = Math::BigInt->new($n);
		}
		elsif ('M' eq $e) {
		    # BigFloat rounding precision is too sticky. It is better not to lock it in.
		    $ret = Math::BigFloat->new($n);
		}
		else {
		    $ret = Pajaro::_mk_double($ret);
		}
	    }
        }
        elsif ($ret eq '/' || $ret eq "/'") { # special case for stand-alone '/' symbol or unchecked-divide
            $ret = clojure::core::symbol($ret);
            if ($$opts{'SQUOTE'}) { $ret=clojure::core::list($QUOTE_SYM, $ret); }
        }
        elsif ($ret eq ':/' || $ret eq ":/'") { # special case for stand-alone '/' keyword or :'
            $ret = clojure::core::keyword($ret);
        }
        elsif ($ret =~ m,^:([^#/]+)(?:/([^/#]+))?$, && $ret !~ /::/) { # Keyword not using a ns alias
            my $a = $1;
            my $b = $2;
            if ($b) { $ret = clojure::core::keyword($a, $b); }
            else { $ret = clojure::core::keyword($a); }
        }
        elsif ($ret =~ m,^::([^0-9#/][^/]*+)(?:/([^0-9][^/]*+))?$, && $ret !~ /::.*::/) { # Keyword using a ns alias
            my $a = $1;
            my $b = $2;
            if ($b) { $ret = clojure::core::keyword("TODO NS-ALIASED-AS-$a", $b); }
            else { $ret = clojure::core::keyword(clojure::core::name(clojure::core::ns_name(clojure::core::deref($clojure::core::_STAR_ns_STAR_))), $a); }
        }
        elsif ($ret eq 'true') { # Boolean
            $ret = builtin::true;
        }
        elsif ($ret eq 'false') { # Boolean
            $ret = builtin::false;
        }
        elsif ($ret eq 'nil') { # nil
            $ret = $NIL;
        }
        elsif ($ret =~ m,^([^:0-9#/][^/]*)(?:/([^0-9][^/]*+))?$, && $ret !~ /::/) { # symbol - simple or qualified
            my $a = $1;
            my $b = $2;
            if ($b) {
                $ret = clojure::core::symbol($a, $b);
                if ($$opts{'SQUOTE'}) {
		    my %aliases = %{clojure::core::deref($clojure::core::_STAR_ns_STAR_)->aliases()};
		    if (exists($aliases{$a})) {
			my $afull = $aliases{$a}->get_name();
			$ret = clojure::core::symbol($afull, $b);
		    }

		    $ret=clojure::core::list($QUOTE_SYM, $ret);
		}
            }
            # TODO when $$opts{'SQUOTE'} decode namespace alias
            else {
                #print STDERR "symbol - simple - '$a'\n";
                if ($$opts{'SQUOTE'}) {
                    #print STDERR "symbol - simple - '$a' inside syntax quote\n";
                    if ($a =~ /(.*)#$/) {
                        # add to SQUOTE environment if not already there
                        my $kernel = $1;
                        if(!exists($$opts{'SQUOTE'}{$a})) {
                            ++$gensym_counter;
                            $$opts{'SQUOTE'}{$a} = clojure::core::symbol("${kernel}__${gensym_counter}__auto__");
                        }
                        $ret = $$opts{'SQUOTE'}{$a};
                        $ret=clojure::core::list($QUOTE_SYM, $ret);
                    }
                    elsif (exists($SPECIAL_FORM{$a})) {
                        #print STDERR "symbol - special form! - '$a' inside syntax quote\n";
                        $ret = clojure::core::list($QUOTE_SYM, clojure::core::symbol($a));
                    }
		    elsif ($a =~ /^\./ || $a =~ /^[^.\/]+\./) {
			# As in Clojure's syntax-quote: .method, Type.Name and Type.Name. are not namespace-qualified
			#print STDERR "read_word_BANG: simple symbol in syntax quote has dot and won't be namespaced: $a\n";
			$ret = clojure::core::list($QUOTE_SYM, clojure::core::symbol($a));
		    }
                    else {
                        #print STDERR "symbol - ordinary - '$a' inside syntax quote\n";
                        # Resolve namespace of unqualified symbol: check for interned reference in *ns*
                        my $ns_intern_ref=clojure::core::deref($clojure::core::_STAR_ns_STAR_)->contents()->{$a};
                        if (clojure::core::var_QMARK_($ns_intern_ref)) {
                            my $body = clojure::core::_symbol_from_var($ns_intern_ref);
                            $ret = clojure::core::list($QUOTE_SYM, $body);
                        }
                        else {
                            my $body = clojure::core::symbol(''. clojure::core::name(clojure::core::ns_name(clojure::core::deref($clojure::core::_STAR_ns_STAR_))), $a);
                            $ret = clojure::core::list($QUOTE_SYM, $body);
                        }
                    }
                }
                elsif ($$opts{'UNQUOTE'}) { # ?
                    #print STDERR "symbol - simple - '$a' - inside unquote\n";
                    $ret = clojure::core::symbol($a);
                    if ($ret->name() =~ /^%/) {
                        $$opts{'ANAPHORIC_ARGS'}{$ret->name()}=$ret;
                    }
                }
                else {
                    #print STDERR "symbol - simple - '$a' - not in syntax quote or unquote\n";
                    $ret = clojure::core::symbol($a);
                    if ($ret->name() =~ /^%/) {
                        $$opts{'ANAPHORIC_ARGS'}{$ret->name()}=$ret;
                    }
                }
            }
        }
        else {
            die("Don't know what to do with<$ret>");
        }
    }
    #if($VERBOSE){print STDERR "read_word_BANG: $ret [".caper::core::_type_perl($ret).']' .caper::core::pr_str($ret)." @ ".cursor_context($cursor)."\n";}
    return $ret;
}

sub reparse_as_perl {
    my $x = shift;
    my $p;
    if ('Pajaro::COWMap' eq ref($x)) {
        my %p;
        for (my $s = clojure::core::seq($x); $s; $s=clojure::core::next($s)) {
            my $e = clojure::core::first($s);
            my $k = clojure::core::key($e);
            my $v = clojure::core::val($e);
            if ('Pajaro.String' eq clojure::core::type($k)->name()) {
                $k = "$k"; # convert to Perl
            }
            elsif (!ref($k)) {
                $k = "$k"; # change number to Perl string
            }
            else {
                die "Perl map key must be a string, not ".ref($k);
            }
            $p{$k}=$v;
        }
        $p=\%p;
    }
    elsif ('Pajaro::COWVector' eq ref($x)) {
        my @p;
        for (my $s = clojure::core::seq($x); $s; $s=clojure::core::next($s)) {
            my $e = clojure::core::first($s);
            push(@p, $e);
        }
        $p=\@p;
    }
    elsif ('Pajaro.String' eq clojure::core::type($x)->name()) {
        $p = "$x";
    }
    else {
        die "Don't know how to reparse as Perl: ".clojure::core::pr_str($x);
    }
    return $p;
}

sub reparse_as_bignum {
    my $reader_literal_tag=shift;
    my $x = shift;
    if ('Math.BigInt' eq $reader_literal_tag) { Math::BigInt->new($x) }
    elsif ('Math.BigFloat' eq $reader_literal_tag) { Math::BigFloat->new($x) }
    elsif ('Math.BigRat' eq $reader_literal_tag) { Math::BigRat->new($x) }
    else { die "Unknown bignum tag" }
}

sub read_readermacro_BANG {
    my $opts = shift;
    my $cursor = shift;
    my $ret;
    my $ch = read_ch_BANG($opts, $cursor);
    die 'EOF' if !defined($ch);
    if ($ch eq '{') {
        putback_ch_BANG($opts, $cursor);
        $ret = read_set_BANG($opts, $cursor);
    }
    elsif ($ch eq '_') { # the 'discard' feature
        skip_space_BANG($opts, $cursor);
        my $skipped = read_form_BANG($opts, $cursor);
        if (nothing_QMARK_($skipped)) { die; }
        $ret = $NOTHING; #undef;
    }
    elsif ($ch eq '(') {
        if ($$opts{'READER_FN'}) {
            die ("Nested #()s are not allowed");
        }
        $$opts{'READER_FN'} = 1;
        $$opts{'ANAPHORIC_ARGS'} = +{};
        putback_ch_BANG($opts, $cursor);
        my $body = read_list_BANG($opts, $cursor);
        # plop the anaphoric arg list and body into something like (fn [%] body)
        my @arglist = sort { clojure::core::name($a) cmp clojure::core::name($b) } (values(%{$$opts{'ANAPHORIC_ARGS'}}));
        $ret = clojure::core::list($FN_SYM, clojure::core::vector(@arglist), $body);
        delete $$opts{'READER_FN'};
    }
    elsif ($ch eq '"') {
        putback_ch_BANG($opts, $cursor);
        $ret = read_regex_BANG($opts, $cursor);
    }
    elsif ($ch =~ /[a-zA-Z]/) {
        putback_ch_BANG($opts, $cursor);
	my $nested_opts = push_opts($opts);
        delete $$nested_opts{'SQUOTE'};
	my $parse_as = read_symbol_name_BANG($nested_opts,$cursor);
        skip_space_BANG($opts, $cursor);
        my $form = read_form_BANG($nested_opts,$cursor);
        if (nothing_QMARK_($form)) { die; }
        if ('perl' eq $parse_as) {
            $ret= reparse_as_perl($form);
        }
	elsif ($parse_as =~ /^(Math.BigInt|Math.BigFloat|Math.BigRat)$/) {
	    $ret=reparse_as_bignum($parse_as, $form);
	}
	elsif ($$opts{'FOREIGN'}) {
	    $ret=42;
        }
	else {
            die "Don't know reader tag $parse_as";
        }
    }
    elsif ($ch eq '#') {
	my $p = read_symbol_name_BANG($opts, $cursor);
	if ($p eq 'Inf') {
	    $ret = builtin::inf(); # 9**9**9;
	}
	elsif ($p eq '-Inf') {
	    $ret = -builtin::inf(); # -9**9**9;
	}
	elsif ($p eq 'NaN') {
	    $ret = builtin::nan(); # 9**9**9 - 9**9**9;
	}
	else {
	    die "What is symbolic value $p?";
	}
    }
    elsif ($ch eq "'") { # i.e., readermacro #' - Var quote
        # turn off syntax quoting in opts because we really want a symbol only, not '(quote ...)
        my $nested_opts = push_opts($opts);
        delete $$nested_opts{'SQUOTE'};
        my $w = read_word_BANG($nested_opts, $cursor);
        if (clojure::core::symbol_QMARK_($w)) {
            $ret = clojure::core::list($VAR_SYM, $w);
            # in syntax quote, resolve simple symbol or default to *ns*
            if ($$opts{'SQUOTE'}) {
                my $v = clojure::core::resolve($w);
                if (defined($v)) {
                    $ret = clojure::core::list($VAR_SYM, clojure::core::_symbol_from_var($v));
                }
                else {
                    $ret = clojure::core::list($VAR_SYM,
                                      clojure::core::symbol(clojure::core::deref($clojure::core::_STAR_ns_STAR_)->get_name(),
                                                   clojure::core::name($w)));
                }
                $ret = clojure::core::list($QUOTE_SYM, $ret);
            }
        }
        else {
            print STDERR ('POINT Z- Instead of symbol, got'.Data::Dumper::Dumper($w)."\n\n".Data::Dumper::Dumper($cursor))."\n\n\nopts=".Data::Dumper::Dumper($opts)."\n\nGood luck\n";
            die('POINT Z'.Data::Dumper::Dumper($cursor));
        }
    }
    elsif ($ch eq "?") { # reader conditional
        $ret = $NOTHING; # pessimistic
        # next char may be @ to splice
        my $splicing;
        my $ch2 = read_ch_BANG($opts, $cursor);
        if ($ch2 eq '@') {
            $splicing=1;
        }
        else {
            putback_ch_BANG($opts, $cursor);
        }
        # list of alternating platform-keyword & stuffing
        $ret = read_reader_conditional_list_BANG($opts, $cursor);
	# https://clojure.org/reference/reader#_reader_conditionals says "Implementors of non-official Clojure platforms should use a qualified keyword for their platform feature to avoid name collisions. Unqualified platform features are reserved for official platforms."
	if ($splicing && !nothing_QMARK_($ret)) {
	    $ret = &clojure::core::vary_meta
		($ret,
		 \&clojure::core::assoc,
		 $_SPLICE_KW,
		 builtin::true);
	}
    }
    else {
        die 'POINT n';
    }
    return $ret;
}
sub skip_thru_eol_BANG {
    my $opts = shift;
    my $cursor = shift;
    for (;;) {
        my $ch = read_ch_BANG($opts, $cursor);
        if (!defined($ch) || $ch eq "\n") {
            last;
        }
    }
}
# Instead of pushback reader, use a string index.
# Caller may pass back the returned element 'end-cursor' as opt 'init-cursor'.
sub read_PLUS_string {
    my $opts = shift;
    if (!exists($$opts{'ENV'}))  {
        $$opts{'ENV'}={};
    }
    if (!exists($$opts{'INDENT'}))  {
        $$opts{'INDENT'}='';
    }
    my $text = shift;
    my $cursor = cursor($text, $$opts{'init-cursor'});
    my $form;
    eval {
        $form = read_form_BANG($opts, $cursor);
    };
    my $e = $@;
    if ($e) {
        if ($e !~ /^EOF/) {
            $e = "Parse error at line $$cursor[CURSOR_LINE] col $$cursor[CURSOR_COL] near <". substr($text, $$cursor[CURSOR_I]-5,10).">: $e";
        }
        die $e;
    }
    my $forms = (nothing_QMARK_($form) ? +[] : +[$form]);
    # If we made no progress at all, throw a syntax error
    if(0==$$cursor[CURSOR_I]) {
	$e = "Parse error: No form begins at line $$cursor[CURSOR_LINE] col $$cursor[CURSOR_COL] near <". substr($text, $$cursor[CURSOR_I]-5,10).">";
	die $e;
    }
    return +{'forms'=>$forms, 'form'=>$form, 'text'=>substr($text, 0, $$cursor[CURSOR_I]), 'end-cursor'=>+{'LINE'=>$$cursor[CURSOR_LINE],
             'COL'=>$$cursor[CURSOR_COL]}};
}

package Pajaro;

# read-string : data structure representing one form read
#  from the string; augmented with metadata:
#    //"SOURCE" - the text that was consumed
#    "FILE" & "LINE" & "COL" - location of the beginning of the form
# opts:
#   "ENV" is Clj lex name => Perl variable (both as Perl strings)
#   "init-cursor" => {'LINE', 'COL'}
#   "NOTHING" => the structure you want back if nothing was read (otherwise the reader dies)
_intern('clojure.core','read-string',
      sub {
	  my @args = @_;
	  my $opts;
	  my $source_code;
	  if (1 == @args) {
	      $opts = +{'ENV'=>+{}}; # Clj lex name => Perl variable (both as Perl strings)
	      $source_code = $args[0];
	  }
	  elsif (2 == @args) {
	      $opts = $args[0];
	      $source_code = $args[1];
	  }
	  else {
	      die;
	  }
	  #print STDERR "\nread-string  : $source_code\n";
          my $form_and_text = Pajaro::Reader::read_PLUS_string($opts, $source_code);
          my $ret;
          if (0 == @{$form_and_text->{'forms'}}) {
              if (exists($$opts{'NOTHING'})) {
                  $ret = $$opts{'NOTHING'};
              }
              else {
                  die "Nothing read";
              }
          }
          else {
              $ret = $form_and_text->{'forms'}->[0];
          }
          my $text = $form_and_text->{'text'};
          # Attach original source text to the form, if it can carry metadata.
          if(0){if (clojure::core::satisfies_QMARK_($clojure::core::IWithMeta,$ret)
              && meta($ret)) {
              $ret = vary_meta(
                  $ret,
                  sub{
                      my $m = shift;
                      assoc($m, 'SOURCE', $text);
                  });
                }}
	  $ret
      });

1;
