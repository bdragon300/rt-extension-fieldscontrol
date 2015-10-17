package RT::Extension::RejectUpdate;

use 5.010;
use strict;
use warnings;
use RT::Tickets;
use RT::Attributes;
use Data::Dumper qw(Dumper);

our $VERSION = '0.1';
our $PACKAGE = __PACKAGE__;

our $available_fields = {
    'Ticket.Requestors'             => 'Requestors',
    'Ticket.Cc'                     => 'Cc',
    'Ticket.AdminCc'                => 'AdminCc',
    'Ticket.Subject'                => 'Subject',
    'Ticket.Content'                => 'Content',
    'Ticket.Attach'                 => 'Attach',
    'Ticket.Status'                 => 'Status',
    'Ticket.Owner'                  => 'Owner',
    'Ticket.Priority'               => 'Priority',
    'Ticket.InitialPriority'        => 'InitialPriority',
    'Ticket.FinalPriority'          => 'FinalPriority',
    'Ticket.TimeEstimated'          => 'TimeEstimated',
    'Ticket.TimeWorked'             => 'TimeWorked',
    'Ticket.TimeLeft'               => 'TimeLeft',
    'Ticket.Starts'                 => 'Starts',
    'Ticket.Due'                    => 'Due',
    'Transaction.MessageType'       => 'UpdateType',
    'Transaction.Worked'            => 'UpdateTimeWorked',
    'Transaction.Content'           => 'UpdateContent',
    'Transaction.Subject'           => 'UpdateSubject',
    'Transaction.One-time-CC'       => 'UpdateCc',
    'Transaction.One-time-Bcc'      => 'UpdateBcc',
    'Transaction.Sign'              => 'Sign',
    'Transaction.Encrypt'           => 'Encrypt'
};

# Empty value in ARGS in that fields means that user did not touch them
our $empty_is_unchanged_fields = {
    'Ticket.Owner'                  => 'Owner',
    'Ticket.Status'                 => 'Status'
};

our $available_ops = {
    'equal'             => sub { (ref($_[0]) eq 'ARRAY') ? int(grep(/^$_[1]$/, @{$_[0]}))  : int($_[0] eq $_[1]); },
    'not equal'         => sub { (ref($_[0]) eq 'ARRAY') ? int(grep(!/^$_[1]$/, @{$_[0]})) : int($_[0] ne $_[1]); },
    'match regex'       => sub { (ref($_[0]) eq 'ARRAY') ? int(grep(/$_[1]/, @{$_[0]})) : int($_[0] =~ /$_[1]/); },
    'not match regex'   => sub { (ref($_[0]) eq 'ARRAY') ? int(grep(!/$_[1]/, @{$_[0]})) : int($_[0] !~ /$_[1]/); },
};

# 'Config value' => 'Display text'
our $aggreg_types = {
    'AND' => sub { 
        int( !! @{$_[0]->{'match'}} && ! @{$_[0]->{'mismatch'}});
    },
    'OR'  => sub { 
        int( !! @{$_[0]->{'match'}});
    }
};

sub get_fields_list {
    my $res = {%$available_fields};

    my $cfs = RT::CustomFields->new( RT::SystemUser );
    $cfs->Limit(FIELD => 'id', OPERATOR => '>=', VALUE => '0');
    while (my $cf = $cfs->Next) {
        $res->{'CF.' . $cf->Name} = $cf->id;
    }

    return $res;
}

sub fill_fields {
    # Returns $available_fields with filled values that sended by user
    # Not passed arguments will be undef

    my $ARGSRef = shift;
    my $ticket = shift;

    my $res = {};
    my $fields = get_fields_list;
    foreach (grep /^Ticket./, keys %$fields) {
        $res->{$_} = (defined $ARGSRef->{$fields->{$_}}) ? $ARGSRef->{$fields->{$_}} : undef;
        if (exists($empty_is_unchanged_fields->{$_})
            && defined($res->{$_})
            && ($res->{$_} eq ''))
        {
            $res->{$_} = $ticket->_Value($empty_is_unchanged_fields->{$_});
        }
    }

    # Special check for Owner
    # RT::Nobody means empty value
    $res->{'Ticket.Owner'} = '' if ($res->{'Ticket.Owner'} eq RT::Nobody->id);

    foreach (grep /^Transaction./, keys %$fields) {
        $res->{$_} = (defined $ARGSRef->{$fields->{$_}}) ? $ARGSRef->{$fields->{$_}} : undef;
    }
    foreach my $cf_abbr (grep /^CF./, keys %$fields) {
        my $cf_id = $fields->{$cf_abbr};
        my @arg_val = grep /^Object-[:\w]+-[0-9]+-CustomField-${cf_id}-Value[^-]?$/, keys %$ARGSRef;
        foreach (@arg_val) {
            $res->{$cf_abbr} = $ARGSRef->{$_};
            last;
        }
    }
    return $res;
}

sub load_config {
    my $attrs = RT::Attributes->new( $RT::SystemUser );
    $attrs->LimitToObject($RT::System);
    $attrs->Limit(FIELD => 'Name', VALUE => 'RejectUpdateConfig');
    $attrs->OrderBy(FIELD => 'id', ORDER => 'DESC');

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

    die "INTERNAL ERROR: [$PACKAGE]: saving config is not array. Something wrong in index.html"
        if (ref $config ne 'ARRAY');

    my $cfg = RT::Attributes->new( RT::SystemUser );
    $cfg->LimitToObject(RT::System);
    $cfg->OrderBy(FIELD => 'id', ORDER => 'DESC');
    my @all_attrs = $cfg->Named('RejectUpdateConfig');
    my $new_cfg = shift @all_attrs if @all_attrs;
    foreach (@all_attrs) {
        $_->Delete;
    }
    unless ($new_cfg) {
        $new_cfg = RT::Attribute->new( RT::SystemUser );
        my $res = $new_cfg->Create(
            Name => 'RejectUpdateConfig',
            Description => 'RT::Extension::RejectUpdate configuration',
            ContentType => 'storable',
            Object => RT::System
        );

        unless ( $res ) {
            RT::Logger->error("[$PACKAGE]: Error while writing settings");
            return $res;
        }
    }

    if (scalar(@{$config})) {
        $new_cfg->SetContent($config);
    } else {
        $new_cfg->DeleteAllSubValues;
    }
    return 0;
}

sub check_ticket {

    my $ticket = shift;
    my $ARGSRef = shift;
    my $errors = [];

    my $config = load_config;
    return $errors unless $config; # No rules
    my $values = fill_fields($ARGSRef, $ticket);

    foreach my $rule (@{$config}) {
        my $res = find_ticket($ticket, $rule->{'searchsql'});
        next unless $res;

        my $sf_aggreg_type = $rule->{'sfieldsaggreg'};
        my $rf_aggreg_type = $rule->{'rfieldsaggreg'};

        my $matches = check_txn_fields($values, $rule->{'sfields'});

        die "INTERNAL ERROR: [$PACKAGE] incorrect config in database. Reconfigure please." 
            unless exists($aggreg_types->{$sf_aggreg_type});
        my $aggreg_res = $aggreg_types->{$sf_aggreg_type}->($matches);

        next if ($aggreg_res == 0 && scalar(@{$rule->{'sfields'}}) > 0); # Apply if no sfields

        $matches = check_txn_fields($values, $rule->{'rfields'});

        die "INTERNAL ERROR: [$PACKAGE] incorrect config in database. Reconfigure please." 
            unless exists($aggreg_types->{$sf_aggreg_type});
        $aggreg_res = $aggreg_types->{$rf_aggreg_type}->($matches);

        my $rule_name = $rule->{'rulename'};
        if ($aggreg_res == 1) {
            push(@$errors, "ERROR: Restriction <$rule_name>, bad fields: [" 
                . join(', ', @{$matches->{'match'}}) 
                . ']');
        }
    }
    return $errors;
}

sub check_txn_fields {
    my $txn_fields = shift;
    my $conf_fields = shift;

    my $res = {
        'match' => [],
        'mismatch' => [],
        'undef' => []
    };

    foreach my $field (@$conf_fields) {
        my $f = $field->{'field'};
        my $op = $field->{'op'};
        my $conf_value = $field->{'value'};

        unless (defined $available_ops->{$op}) 
        {
            die "INTERNAL ERROR: [$PACKAGE] incorrect config in database. Reconfigure please.";
        }

        my $new_value = $txn_fields->{$f};
        # next unless defined $new_value;

        unless (defined $new_value) {
            push @{$res->{'undef'}}, $f;
            next;
        }
        my $op_res = $available_ops->{$op}($new_value, $conf_value);
        if ($op_res) {
            push @{$res->{'match'}}, $f;
        } else {
            push @{$res->{'mismatch'}}, $f;
        }
    }

    return $res;
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

