# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

package Pajaro::Salt;

## Salt - Serializes Perl code

=pod

The C<toPerl> subroutine writes Perl code, given a tree of
Pajaro::Salt::Term "nodes".

To make that tree, there are about 39 constructors, each devoted to a
particular kind of syntax. As a rule, these subroutines take a
source-map parameter, which is a ref to a 2-item array containing a
line number and a filename, and one or more "nodes" as content. Each
node of content is a string or an instance of Pajaro::Salt::Term.

=over

=item C<verbatimPerl($cite, $stuff)>

Verbatim stuff.

=item C<stringLiteral($cite, $text)>

String literal expression
(chooses suitable quoting mechanism and escapes special characters).

=item C<assign($cite, $lvalueNode, $rvalueNode)>

Assignment expression node
(C<lvalue = rvalue>).

=item C<ClojureList($cite, @itemNodes)>

C<&Pajaro::PEPR::list( item1, item2, ... )>

=item C<PerlList($cite, @itemNodes)>

C<( item1, item2, ... )>

=item C<PerlArrayRef($cite, @itemNodes)>

C<+[ item1, item2, ... ]>

=item C<callClassMethod($cite, $class, $method, @argNodes)>

C<method Class( arg1, arg2, ... )>

=item C<callInstanceMethod($cite, $object, $method, @argNodes)>

C<object-\>method( arg1, arg2, ... )>

=item C<callFunction($cite, $function, @argNodes)>

C<&{function}( arg1, arg2, ... )>.

=item C<perlSub($cite, 'subName', $content)>

C<sub subName { ... }>

=item C<lambda($cite, @stmtOrExprNodes)>

C<sub{ ... }>

=item C<namedLambda($cite, $localVarName, @stmtOrExprNodes)>

C<&{sub{my $v; $v=sub{...}}}()> (a self-referencing named lambda expression
node). If localVarName is undef, then the output is the same as from lambda.

=item C<perlMapLiteral($cite, $kNode, $vNode, ...)>

C<+{k1, v1, ...}> (Perl hash reference expression node from alternating
key-value pairs).

=item C<statement($cite, @termNodes)>

C< term1 term2 term3 ; > (Semicolon-terminated statement
from space-separated expression terms)

=item C<statements($cite, @stmts)>

Sequence-of-statements node. (Does not add separators.)

=item C<block($cite, @terms)>

C<{ ... }>. Terms may be 1 expression or N statements.

=item C<evalBlock($cite, @terms)>

C<eval { ... }>. Terms may be 1 expression or N statements.

=item C<ifElsif($cite, expr1, stmts1)>

C<if (expr1) { stmts1 } elsif (expr2) { ...> from alternating
condition/body pairs.

=item C<label($cite, $name)>

Label node (C<name:>) to be used
inside a statement or between statements

=item C<declareMy($cite, $scopeWord, $varname, $assignment)>

scopeWord
should be 'my' or 'our'. Variable declaration statement node
(C<my $var = ...;>).

=item C<goto_($cite, $destination)>

Goto statement node (C<goto destination;>).

=item C<hashPtr($term)>

Hash reference expression node wrapping a
term in C<+{...}>. The source map location comes from term.

=item C<arrayPtr($term)>

Array reference expression node wrapping a
term in C<+[...]>. The source map location comes from term.

=item C<infix($operator, @args)>

Infix operator expression node
(C<(a op b op ...)>). The source map location comes from the first term
in args.

=back

=cut

use strict;

# Term is a seq of tokens, an 'expression?' flag, and a source citation,
# Whitespace is automatically inserted as needed to separate tokens or words within a term.

use constant { EXPR=>1, BLOCK=>2, STRUCT=>4, SEMITERM=>8 };

{
    package Pajaro::Salt::Term;
    use constant { CITE_SLOT=>0, IS_EXPRESSION_SLOT=>1, TOKENS_SLOT=>2 };
    sub new { # tokens are strings or Terms
        my $class = shift;
        my $cite = shift;
        my $isExpression = shift; # bit 0=expression, bit 1=block, bit 2=flow like if(){}
        my @tokens = @_;
        my $self = +[$cite, $isExpression, +[@tokens]];
        bless($self, $class)
    }
    sub cite { my $this = shift; $$this[CITE_SLOT] }
    sub isExpression {
        my $this = shift; Pajaro::Salt::EXPR & $$this[IS_EXPRESSION_SLOT] }
    sub isBlock {
        my $this = shift; Pajaro::Salt::BLOCK & $$this[IS_EXPRESSION_SLOT] }
    sub isStructure {
        my $this = shift; Pajaro::Salt::STRUCT & $$this[IS_EXPRESSION_SLOT] }
    sub needsSemicolon {
        my $this = shift; Pajaro::Salt::SEMITERM & $$this[IS_EXPRESSION_SLOT] }
    sub tokens {
        my $this = shift; $$this[TOKENS_SLOT] } # tokens are strings or Terms
}

# citation is +[line, file]
sub citationComment {
    my $c = shift;
    '# line '.$$c[0].' "'.$$c[1].'"'
}

sub _toPerl { # modifies context by adding to STRS and updating CITE
    my $context = shift; # +{CITE=>, STRS=>+[..strings..]}
    my $tokens = shift;
    my $priorNeedsSemicolon = 0;
    for my $token (@$tokens) {
        # terminate prior
        if ($priorNeedsSemicolon) {
            push(@{$$context{STRS}}, q(;));
            $priorNeedsSemicolon=0;
        }
        if ('Pajaro::Salt::Term' eq ref($token)) {
            # new source line?
            if (defined($token->cite()->[0])) {
                my $nowCite = citationComment($token->cite());
                my $lastCited = citationComment($$context{CITE});
                if ($lastCited ne $nowCite) {
                    # newline
                    if (@{$$context{STRS}}) {
                        push(@{$$context{STRS}}, "\n");
                    }
                    # if other than next line in sequence, cite
                    my $nextCite = citationComment
                        (+[1+$$context{CITE}[0], $$context{CITE}[1]]);
                    if ($nextCite ne $nowCite) {
                        push(@{$$context{STRS}}, qq($nowCite\n));
                    }
		    $$context{'CITE'}=$token->cite()
                }
            }
            # terminate later, conditionally
            $priorNeedsSemicolon = $token->needsSemicolon();
            # append content
            _toPerl($context, $token->tokens())
        }
        else { # string
            die "uh oh".ref($token) if(ref($token));
            # separate?
            if ($token =~ /^[-_a-zA-Z0-9]/
                && $$context{STRS}[-1]
                && $$context{STRS}[-1] =~ /[-_a-zA-Z0-9]$/) {
                push(@{$$context{STRS}}, ' ');
            }
            # append
            push(@{$$context{STRS}}, $token);
        }
    }
    $context;
}

sub toPerl {
    my @tokens = @_;
    my @strs;
    _toPerl(+{'CITE'=>+[undef,undef], 'STRS'=>\@strs}, \@tokens);
    join('', @strs)
}

sub _toPerl_NoCitations { # modifies context by adding to STRS
    my $context = shift; # +{CITE=>, STRS=>+[..strings..]}
    my $tokens = shift;
    my $priorNeedsSemicolon = 0;
    for my $token (@$tokens) {
        # terminate prior
        if ($priorNeedsSemicolon) {
            push(@{$$context{STRS}}, q(;));
            $priorNeedsSemicolon=0;
        }
        if ('Pajaro::Salt::Term' eq ref($token)) {
            # terminate later, conditionally
            $priorNeedsSemicolon = $token->needsSemicolon();
            # append content
            _toPerl($context, $token->tokens())
        }
        else { # string
            die "uh oh".ref($token) if(ref($token));
            # separate?
            if ($token =~ /^[-_a-zA-Z0-9]/
                && $$context{STRS}[-1]
                && $$context{STRS}[-1] =~ /[-_a-zA-Z0-9]$/) {
                push(@{$$context{STRS}}, ' ');
            }
            # append
            push(@{$$context{STRS}}, $token);
        }
    }
    $context;
}

sub toPerl_NoCitations {
    my @tokens = @_;
    my @strs;
    _toPerl_NoCitations(+{'CITE'=>+[undef,undef], 'STRS'=>\@strs}, \@tokens);
    join('', @strs)
}

sub stringLiteral {
    my $cite = shift;
    my $p = shift;
    my @qqdelims = ('(',')');
    my %detox = map(($_=>1),
                    (@qqdelims, q('), q("), q(\\), q($), q(@)));
    my $interpolation_needed = 0; # for hex escapes, not variables
    for (my $i = length($p)-1; $i>=0; $i--) {
        my $c = substr($p, $i, 1);
        my $o = ord($c);
        my $d = ($o < 32 || $o >127 || exists($detox{$c}))
            ? sprintf('\\x{%x}',$o)
            : undef;
        if ($d) {
            substr($p,$i,1)=$d;
            $interpolation_needed=1;
        }
    }
    my $op = $interpolation_needed?'qq':'q';
    new Pajaro::Salt::Term($cite, EXPR, $op, $qqdelims[0], $p, $qqdelims[1])
}

sub regexpLiteral {
    my $cite = shift;
    my $p = shift;
    my $pat = "$p";
    # correct for repeated sheathing with (?^: ... )
    if (substr($pat, 0, 4) eq '(?^:'
        && substr($pat, -1, 1) eq ')') {
        $pat=substr($pat, 4, -1);
    }
    # Use a Perl regex literal if we can figure out how to avoid interpolation.
    # (a) If pattern does not use apostrophe, then qr'...' -- it is the non-interpolating delimiter
    # (b) Otherwise use an IIFE.
    if ($pat =~ /'/) {
        callFunction
            ($cite,
             lambda($cite,
                    statements
                    ($cite,
                     statement($cite, declareMy($cite, 'my', '$x', stringLiteral($cite, $pat))),
                     new Pajaro::Salt::Term($cite, EXPR, 'qr'.'($x)'))));
    }
    else {
        new Pajaro::Salt::Term($cite, EXPR, "qr'".$pat."'")
    }
}

sub isExpression {
    my $t = shift;
    if (!defined($t)) {
        1;
    }
    elsif (!ref($t)) {
        1;
    }
    else {
        $t->isExpression()
    }
}

sub asExpression {
    my $t = shift;
    if (!defined($t)) {
        $t
    }
    elsif (!ref($t)) {
        $t
    }
    elsif ($t->isExpression()) {
        $t
    }
    else {
        new Pajaro::Salt::Term($t->cite(), EXPR,
                             callFunction($t->cite(),
                                          lambda($t->cite(), $t), ()))
    }
}

sub asBlock {
    my $t = shift; # must be a Term b/c must have a citation
    if ($t->isBlock()) {
        $t
    }
    else {
        block($t->cite(), $t)
    }
}

sub separateByComma { # accepts a list of terms and returns a list of 0 or 1 expression term
    my @terms = @_;
    { # sanity
        for my $term (@terms) {
            if (!isExpression($term)) {
                die "uh oh separateByComma should not mislabel a non-expression\n";
            }
        }
    }
    if (@terms) {
        my @sepTerms = ();
        for my $term (@terms) {
            if (@sepTerms) { push @sepTerms, ',' }
            push @sepTerms, asExpression($term)
        }
        (new Pajaro::Salt::Term($terms[0]->cite(), EXPR, @sepTerms))
    }
    else {
        @terms
    }
}

sub verbatimPerl {
    my $cite = shift;
    my $p = shift;
    {
        my $sanity = toPerl($p);
        if ($sanity =~ /;/) {
            warn "Uh oh verbatimPerl will call this an EXPR but I see a semicolon";
        }
    }
    new Pajaro::Salt::Term($cite, EXPR, $p)
}
*rawExpression = \*verbatimPerl;

sub wrapParens {
    my $cite = shift;
    my @terms = @_;
    { # sanity
        for my $term (@terms) {
            if (!isExpression($term)) {
                die "uh oh wrapParens should not mislabel a non-expression\n";
            }
        }
    }
    new Pajaro::Salt::Term($cite, EXPR, '(', @terms, ')')
}

sub PerlList {
    my $cite = shift;
    my @terms = @_;
    new Pajaro::Salt::Term($cite, EXPR, wrapParens($cite, separateByComma(map(asExpression($_), @terms))))
}

sub PerlArrayRef {
    my $cite = shift;
    my @terms = @_;
    new Pajaro::Salt::Term($cite, EXPR, '+[', separateByComma(@terms), ']')
}

sub perlMapLiteral {
    my $cite = shift;
    my @kvkvs = map(asExpression($_), @_);
    my @words;
    for my ($k, $v) (@kvkvs) {
        if (@words) { push(@words, ',') }
        push(@words, $k, '=>', asExpression($v));
    }
    new Pajaro::Salt::Term($cite, EXPR, '+{', @words, '}');
}

sub perlSub {
    my $cite = shift;
    my $subName = shift;
    my @content = @_; # should be Salts
    new Pajaro::Salt::Term($cite, BLOCK, new Pajaro::Salt::Term($cite, EXPR, 'sub', $subName, block($cite, @content)))
}

sub lambda { # 1 expression or 1 statements node
    my $cite = shift;
    my $content = shift;
    new Pajaro::Salt::Term($cite, EXPR, 'sub', '{', $content, '}')
}

sub callFunction {
    my $cite = shift;
    my $funcTerm = shift;
    my @args = @_;
    my $txt = toPerl_NoCitations($funcTerm);
    my $needsBraces = ($txt !~ /^[_a-zA-Z:][_0-9a-zA-Z:]*$/);
    my @funcRef = $needsBraces ? ('{', $funcTerm, '}') : ($funcTerm);
    # NO SPACE is desired between funcRef and the arg list.
    # A space can make the parenthesis ambiguous.
    new Pajaro::Salt::Term($cite, EXPR, '&', @funcRef, PerlList($cite, @args))
}

sub callBuiltin {
    my $cite = shift;
    my $funcTerm = shift;
    my @args = @_;
    my $txt = toPerl_NoCitations($funcTerm);
    # NO SPACE is desired between funcRef and the arg list.
    # A space can make the parenthesis ambiguous.
    new Pajaro::Salt::Term($cite, EXPR, $funcTerm, PerlList($cite, @args))
}

sub declareMy {
    my $cite = shift;
    my $perlCommand = shift; # e.g., "my"
    my $localVarName = shift;
    my $optionalRvalue = shift;
    if ($localVarName =~ /_COLON__COLON_/) {
	die "Oooooops localVarName $localVarName";
    }
    our @words = ($perlCommand, $localVarName);
    if (defined($optionalRvalue)) {
        push(@words,'=');
        push(@words, asExpression($optionalRvalue));
    }
    new Pajaro::Salt::Term($cite, SEMITERM, @words)
}

sub declareHoist {
    my $cite = shift;
    my $globalVarName = shift;
    my $rvalue = shift;
    if ($globalVarName =~ /_COLON__COLON_/) {
	die "Oooooops globalVarName $globalVarName";
    }
    our @words = ($globalVarName);
    push(@words,'//=');
    push(@words, asExpression($rvalue));
    Pajaro::Salt::wrapParens($cite, new Pajaro::Salt::Term($cite, EXPR, @words))
}

sub assign { # no semicolon is added. lvalue includes sigil
    my $cite = shift;
    my $lvalue = shift;
    my $rvalue = shift;
    new Pajaro::Salt::Term($cite, EXPR, asExpression($lvalue), '=', asExpression($rvalue))
}

sub abutting { # stuff is statements, not terminated by semicolons
    my $cite = shift;
    my @stuff = @_; # might be empty
    new Pajaro::Salt::Term($cite, 0, @stuff);
}
*statements = \&abutting;

sub namedLambda { # self-referential function ; if funcName isn't defined, it's just a plain lambda. content is 1 expr or 1 statements
    my $cite = shift;
    my $funcLocalVar = shift; # incl $ sigil
    my $content = shift;
    if ($funcLocalVar) {
        # &{sub{...}}(...)
        # &{set_subname 'xxx', sub{...}}(...)
        callFunction($cite,
                     lambda($cite,
                            statements(
                                $cite,
                                declareMy($cite, 'my', $funcLocalVar),
                                assign($cite, $funcLocalVar,
                                       callFunction($cite, 'Sub::Util::set_subname', stringLiteral($cite, , substr($funcLocalVar,1)),

                                                    lambda($cite, $content)))),
                            ()))
    }
    else {
        lambda($cite, $content)
    }
}

sub callClassMethod {
    my $cite = shift;
    my $perlclass = shift;
    my $method = shift;
    my @args = @_;
    #new Pajaro::Salt::Term($cite, EXPR, $method, ' ', $perlclass, PerlList($cite, @args))
    # NO SPACE is desired between method and the arg list.
    # A space can make the parenthesis ambiguous.
    new Pajaro::Salt::Term($cite, EXPR, $perlclass, '->', $method, PerlList($cite, @args))
}

sub callInstanceMethod {
    my $cite = shift;
    my $object = shift;
    my $method = shift;
    my @args = @_;
    # NO SPACE is desired between method and the arg list.
    # A space can make the parenthesis ambiguous.
    new Pajaro::Salt::Term($cite, EXPR, asExpression($object), '->', $method, PerlList($cite, @args))
}

sub ClojureList {
    my $cite = shift;
    my @stuff = @_;
    callFunction('clojure::core::list', @_)
}

sub label {
    my $cite = shift;
    my $label = shift;
    new Pajaro::Salt::Term($cite, 0, "$label:")
}

sub statement { # stuff is words within a statement, not including terminal semicolon
    my $cite = shift;
    my @stuff = @_;
    die unless @stuff;
    new Pajaro::Salt::Term($cite, SEMITERM, @stuff)
}

sub goto_ {
    my $cite = shift;
    my $target = shift;
    statement($cite, verbatimPerl($cite,'goto'), $target)
}

sub block { # stuff is statements, or list of 1 expression
    my $cite = shift;
    my @stuff = @_;
    new Pajaro::Salt::Term($cite, BLOCK, '{', abutting($cite, @stuff), '}')
}

sub evalBlock { # stuff is statements, or list of 1 expression
    my $cite = shift;
    my @stuff = @_;
    new Pajaro::Salt::Term($cite, EXPR, 'eval'.'{', abutting($cite, @stuff), '}')
}

sub ifElsif {
    my $cite = shift;
    my @pairs=@_; # [ expression, block, ..., else-block? ]
    if (3==@pairs # ternary operator
        && isExpression($pairs[1])
        && isExpression($pairs[2])) {
        my $ternary = wrapParens
             ($pairs[0]->cite(),
              ' ', # prevent the wrapper parens from seeming to be an arglist
              asExpression($pairs[0]),
              ' ? ',
              $pairs[1], ' : ',
              $pairs[2]);
        $ternary;
    }
    else {
        my @terms = ();
        while (@pairs) {
            if (@pairs > 1) {
                my $expr = shift(@pairs);
                my $block = shift(@pairs);
                my $verb = @terms ? 'elsif' : 'if';
                push(@terms, $verb,
                     wrapParens($expr->cite(), asExpression($expr)),
                     asBlock($block))
            }
            else {
                my $block = shift(@pairs);
                if ($block) {
                    push(@terms, 'else', asBlock($block))
                }
            }
        }
        new Pajaro::Salt::Term($cite, STRUCT, @terms)
    }

}

sub hashPtr { # wraps x, presumably useful in array context, in +{, }
    my $x = shift;
    die "Required" unless $x;
    new Pajaro::Salt::Term($x->cite(), EXPR, '+{', asExpression($x), '}')
}
sub arrayPtr { # wraps x, presumably useful in array context, in +[, ]
    my $x = shift;
    die "Required" unless $x;
    new Pajaro::Salt::Term($x->cite(), EXPR, '+[', asExpression($x), ']')
}
sub infix {
    my $operator = shift;
    my @operands = @_;
    die unless (@operands > 1);
    my @words = ();
    for my $o (@operands) {
        if(@words) {
	    # Spaces: )*Foo can read as a glob, )%Foo as a hash [Claude]
	    push(@words,' ',$operator,' ')
	}
        push(@words, asExpression($o))
    }
    wrapParens($operands[0]->cite(), @words)
}
sub unary {
    my $operator = shift;
    my $operand = shift;
    my @words = ();
    # Space: prevent unary - followed by a negative number from becoming --, predecrement [Claude]
    push(@words, ' ',$operator, ' ');
    push(@words, asExpression($operand));
    wrapParens($operand->cite(), @words)
}

sub hashMember {
    my $hash=shift;
    my $member=shift;
    new Pajaro::Salt::Term($hash->cite(), EXPR, '${', $hash, '}', '{', $member ,'}')
}

sub arrayMember {
    my $arr=shift;
    my $member=shift;
    new Pajaro::Salt::Term($arr->cite(), EXPR, '${', $arr, '}', '[', $member ,']')
}

1;
