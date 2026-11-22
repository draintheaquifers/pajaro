# Copyright (c) 2026 by Phill Wolf. All rights reserved.
# The use and distribution terms for this software are covered by the Eclipse Public
# License 1.0 (http://opensource.org/licenses/eclipse-1.0.php) which can
# be found in the file epl-v10.html at the root of this distribution.
# By using this software in any fashion, you are agreeing to be bound by
# the terms of this license.
# You must not remove this notice, or any other, from this software.

package Pajaro::ToStringHandle;

sub TIEHANDLE {
    my ($class, $processor) = @_;
    my $self = {
        processor => $processor
    };
    return bless $self, $class;
}
sub PRINT {
    my $self = shift;
    foreach my $text (@_) {
        $self->{processor}->($text);
    }
    return 1;
}
sub PRINTF {
    my $self = shift;
    my $fmt = shift;
    my $text = sprintf($fmt, @_);
    return $self->PRINT($text);
}
sub CLOSE {
    my $self = shift;
    # to-string does not need finalization
    return 1;
}

1;
