package RT::Extension::RejectUpdate;

use 5.010;
use strict;
use warnings;
use RT::Tickets;
use RT::Attributes;
use Data::Dumper qw(Dumper);

our $VERSION = '0.1';
our $PACKAGE = __PACKAGE__;

our $available_fields = [
    ## Message details
    'Ticket::Requestors',
    'Ticket::Cc',
    'Ticket::AdminCc',
    'Ticket::Subject',
    'Ticket::Content',
    'Ticket::Attach',
    ## Meta data
    'Ticket::Status',
    'Ticket::Owner',
    ## Basics
    'Ticket::Priority',
    'Ticket::InitialPriority',
    'Ticket::FinalPriority',
    'Ticket::TimeEstimated',
    'Ticket::TimeWorked',
    'Ticket::TimeLeft',
    ## Dates
    'Ticket::Starts',
    'Ticket::Due',
    ## Links
    'Ticket::new-DependsOn',
    'Ticket::DependsOn-new',
    'Ticket::new-MemberOf',
    'Ticket::MemberOf-new',
    'Ticket::new-RefersTo',
    'Ticket::RefersTo-new',
    'Transaction::UpdateTimeWorked'
];

our $available_ops = {
    '==' => sub { $_[0] eq $_[1]; },
    '!=' => sub { $_[0] ne $_[1]; },
    '=~' => sub { $_[0] =~ /$_[1]/; },
    '!~' => sub { $_[0] !~ /$_[1]/; }
};

sub retrieve_mason_args {
    my $ARGSRef = shift;

    my %res = ();
    foreach (map /::(\S+)$/, grep /^Ticket/, @$available_fields) {
        $res{'Ticket::' . $_} = (defined $ARGSRef->{$_}) ? $ARGSRef->{$_} : undef;
    }

    foreach (map /::(\S+)$/, grep /^Transaction/, @$available_fields) {
        $res{'Transaction::' . $_} = (defined $ARGSRef->{$_}) ? $ARGSRef->{$_} : undef;
    }

    return \%res;
}

sub load_config {
    my $attrs = RT::Attributes->new( $RT::SystemUser );
    $attrs->LimitToObject($RT::System);
    $attrs->Limit(FIELD => 'Name', VALUE => 'RejectUpdateConfig');

    my $cfg = ($attrs->Count > 0) ? $attrs->First->Content : undef;
    if (ref($cfg) eq 'ARRAY') {
        return $cfg;
    } elsif (defined $cfg) {
        RT::Logger->warning("[$PACKAGE]: Incorrect settings format in database");
    }
    return (undef);
}

sub write_config {
    my $config = shift;

    die "config is not array" if (ref $config ne 'ARRAY');

    my $cfg = RT::Attributes->new( RT::SystemUser );
    $cfg->LimitToObject(RT::System);
    my @all_attrs = $cfg->Named('RejectUpdateConfig');
    foreach (@all_attrs) {
        $_->Delete;
    }

    if (scalar(@{$config})) {
        my $new_cfg = RT::Attribute->new( RT::SystemUser );
        my $res = $new_cfg->Create(
            Name => 'RejectUpdateConfig',
            Description => 'RT::Extension::RejectUpdate configuration',
            Content => $config,
            ContentType => 'storable',
            Object => RT::System
        );
        if ( ! $res ) {
            RT::Logger->error("[$PACKAGE]: Error while writing settings");
        }
        return $res;
    }
    return 0;
}

sub check_ticket {
    # Returns (0|1, 'error message')

    my $ticket = shift;
    my $ARGSRef = shift;

    my $config = load_config;
    return (1, '') unless $config; #No rules or error
    my $values = retrieve_mason_args($ARGSRef);
    my @incorrect_fields = ();

    foreach my $rule (@{$config}) {
        my $res = find_ticket($ticket, $rule->{'searchsql'});
        next unless $res;

        my $rule_name = $rule->{'rulename'};
        foreach my $field (@{$rule->{'fields'}}) {
            my $f = $field->{'field'};
            my $op = $field->{'op'};
            my $val = $field->{'value'};

            unless (defined $available_ops->{$op}) 
            {
                return (0, 'ERROR: Incorrect config: rule ' . $rule_name . ' field ' . $f);
            }

            my $field_value = $values->{$f};
            next unless defined $field_value;

            my $op_res = $available_ops->{$op}($field_value, $val);
            if ($op_res) {
                push @incorrect_fields, $f;
            }
        }
        return (0, "ERROR: Restriction <$rule_name>, bad fields: [" . join(', ', @incorrect_fields) . ']') if @incorrect_fields;
    }
    return (1, '');
}

sub find_ticket {
    my $ticket = shift;
    my $sql = shift;

    my $tickets = RT::Tickets->new( RT::SystemUser );

    # Search SQL
    my ($res, $msg) = $tickets->FromSQL($sql);
    unless ($res) {
        RT::Logger->error("[$PACKAGE]: Error while parsing search SQL: " . $sql);
        return 0;
    }
    $tickets->Limit(FIELD => 'id', VALUE => $ticket->id, ENTRYAGGREGATOR => 'AND');
    unless (my $found = $tickets->First) {
        return 0;
    }

    return 1;
}

