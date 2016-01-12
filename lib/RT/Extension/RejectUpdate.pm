package RT::Extension::RejectUpdate;

use 5.010;
use strict;
use warnings;
use RT::Tickets;
use RT::Attributes;
use RT::CustomField;
use Data::Dumper qw(Dumper);

our $VERSION = '0.1';
our $PACKAGE = __PACKAGE__;

our $available_fields = {
    'Ticket.Subject'                => 'Subject',
    'Ticket.Status'                 => 'Status',
    'Ticket.Owner'                  => 'Owner',
    'Ticket.Priority'               => 'Priority',
    'Ticket.InitialPriority'        => 'InitialPriority',
    'Ticket.FinalPriority'          => 'FinalPriority',
    'Ticket.TimeEstimated'          => 'TimeEstimated',
    'Ticket.TimeWorked'             => 'TimeWorked',
    'Ticket.TimeLeft'               => 'TimeLeft',
    'Ticket.Queue'                  => 'Queue',
    'Transaction.Attach'            => 'Attach',
    'Transaction.Content'           => 'Content',
    'Transaction.Worked'            => 'UpdateTimeWorked',
    'Transaction.Content'           => 'UpdateContent',
    'Transaction.Subject'           => 'UpdateSubject',
    'Transaction.One-time-CC'       => 'UpdateCc',
    'Transaction.One-time-Bcc'      => 'UpdateBcc',
    'Transaction.Sign'              => 'Sign',
    'Transaction.Encrypt'           => 'Encrypt',
    'Transaction.Type'              => '__Dynamic__'
};

# Empty value in ARGS in that fields means that user did not touch them
our $empty_is_unchanged_fields = {
    'Ticket.Owner'                  => 'Owner',
    'Ticket.Status'                 => 'Status'
};

our $available_ops = {
    'equal'             => sub { (ref($_[0]) eq 'ARRAY') ? int(grep(/^$_[1]$/, @{$_[0]}))  : int($_[0] eq $_[1]); },
    'not equal'         => sub { (ref($_[0]) eq 'ARRAY') ? int( ! grep(/^$_[1]$/, @{$_[0]})) : int($_[0] ne $_[1]); },
    'match regex'       => sub { (ref($_[0]) eq 'ARRAY') ? int(grep(/$_[1]/, @{$_[0]})) : int($_[0] =~ /$_[1]/); },
    'not match regex'   => sub { (ref($_[0]) eq 'ARRAY') ? int( ! grep(/$_[1]/, @{$_[0]})) : int($_[0] !~ /$_[1]/); },
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

sub fill_ticket_fields {
    my $fields = shift;
    my $ticket = shift;

    my $res = {};
    foreach my $f (grep /^Ticket./, keys %$fields) {
        my ($fld) = $f =~ /Ticket.(.*)/;
        $res->{$f} = $ticket->_Value($fld);
    }
    my $cfs = $ticket->CustomFields;
    while (my $cf = $cfs->Next) {
        my $cf_name = 'CF.' . $cf->Name;
        next unless exists $fields->{$cf_name};

        my $vals = $cf->ValuesForObject($ticket);
        if ($vals->Count == 0) {
            $res->{$cf_name} = '';
        } elsif ($vals->Count == 1) {
            $res->{$cf_name} = $vals->First->Content;
        } else {
            my @val = ();
            while (my $v = $vals->Next) {
                push @val, $v->Content;
            }
            $res->{$cf_name} = [@val];
        }
    }
    return $res;
}

sub fill_txn_fields {
    # Returns $available_fields with filled values that sended by user
    # Not passed arguments will be undef

    my $fields = shift;
    my $ticket = shift;
    my $ARGSRef = shift;
    my $callback_name = shift;

    my $res = {};
    foreach (grep /^Ticket./, keys %$fields) {
        $res->{$_} = $ARGSRef->{$fields->{$_}} if (defined $ARGSRef->{$fields->{$_}});

        # If empty then retrieve it from TicketObj
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
        $res->{$_} = $ARGSRef->{$fields->{$_}} if (defined $ARGSRef->{$fields->{$_}});
    }
    foreach my $cf_abbr (grep /^CF./, keys %$fields) {
        my $cf_id = $fields->{$cf_abbr};
        my @arg_val = grep /^Object-[:\w]+-[0-9]+-CustomField-${cf_id}-Value[^-]?$/, keys %$ARGSRef;
        $res->{$cf_abbr} = $ARGSRef->{$arg_val[0]} if (@arg_val);
    }

    # Transaction.Type
    if (ucfirst $callback_name eq 'Update') {
        if (exists $ARGSRef->{'UpdateType'} &
            $ARGSRef->{'UpdateType'} eq 'private')
        {
            $res->{'Transaction.Type'} = ['Comment', 'Update', 'Status'];
        } else {
            $res->{'Transaction.Type'} = ['Correspond', 'Update', 'Reply', 'Status'];
        }
    } elsif (ucfirst $callback_name eq 'Modify') {
        $res->{'Transaction.Type'} = ['Set', 'Basics', 'Modify', 'CustomField', 'Status'];
    } elsif (ucfirst $callback_name eq 'ModifyAll') {
        $res->{'Transaction.Type'} = ['Jumbo', 'ModifyAll', 'Status'];
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
        RT::Logger->warning("[$PACKAGE]: Incorrect settings format in database"); #FIXME: shows when settings are empty
    }
    return (undef); #FIXME: must return []
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
        return $new_cfg->SetContent($config);
    } else {
        return $new_cfg->DeleteAllSubValues;
    }
}

sub check_ticket {

    my $ticket = shift;
    my $ARGSRef = shift;
    my $callback_name = shift;
    my $errors = [];

    my $config = load_config;
    return $errors unless $config; # No rules
    return $errors unless exists($ARGSRef->{'SubmitTicket'});

    my $fields = get_fields_list;
    my $txn_values = fill_txn_fields($fields, $ticket, $ARGSRef, $callback_name);
    my $ticket_values = fill_ticket_fields($fields, $ticket);

    foreach my $rule (@{$config}) {
        my $res = find_ticket($ticket, $rule->{'searchsql'});
        next unless $res;

        my $sf_aggreg_type = $rule->{'sfieldsaggreg'};
        my $rf_aggreg_type = $rule->{'rfieldsaggreg'};

        my $matches = check_txn_fields($txn_values, $rule->{'sfields'});

        die "INTERNAL ERROR: [$PACKAGE] incorrect config in database. Reconfigure please." 
            unless exists($aggreg_types->{$sf_aggreg_type});
        my $aggreg_res = $aggreg_types->{$sf_aggreg_type}->($matches);

        # Apply rule if no sfields or all ones are undef
        if ($aggreg_res == 0 
            && (scalar(@{$matches->{'match'}}) > 0
                || scalar(@{$matches->{'mismatch'}}) > 0)
        )
        {
            next;
        } 

        my $rvalues = {%$ticket_values, %$txn_values};
        $matches = check_txn_fields($rvalues, $rule->{'rfields'});

        die "INTERNAL ERROR: [$PACKAGE] incorrect config in database. Reconfigure please." 
            unless exists($aggreg_types->{$rf_aggreg_type});
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

