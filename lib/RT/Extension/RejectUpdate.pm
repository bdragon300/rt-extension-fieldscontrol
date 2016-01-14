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

=head1 NAME

RT::Extension::RejectUpdate - Rejects page update while updating ticket based on fields value

=head1 DESCRIPTION

Just after user click on Update Ticket button (or Save Changes) the extension
validate ticket and transaction fields value according on preconfigured rules.
If some rules are match then user will stay on the same page and error message
will point which matching fields list. If no rules was match then ticket update
will not be interrupted.

=head1 INSTALLATION

=over

=item C<perl Makefile.PL>

=item C<make>

=item C<make install>

May need root permissions

=item Edit your RT_SiteConfig.pm

If you are using RT 4.2 or greater, add this line:

    Plugin('RT::Extension::RejectUpdate');

For RT 3.8 and 4.0, add this line:

    Set(@Plugins, qw(RT::Extension::RejectUpdate));

or add C<RT::Extension::RejectUpdate> to your existing C<@Plugins> line.

=item Restart your webserver

=back

=head1 CONFIGURATION

See README.md

=head1 AUTHOR

Igor Derkach, E<lt>gosha753951@gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2015 Igor Derkach, E<lt>https://github.com/bdragon300/E<gt>

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

Request Tracker (RT) is Copyright Best Practical Solutions, LLC.


=cut

=head1 ATTRIBUTES

=head2 $available_fields

Hash that describes available fields (besides CustomFields) that can be set by
user in "old state" and "checking fields" sections in configuration. 
<Displaying name> => <%ARGS key> 
Some of these fields are building dynamically such as Transaction.Type

=cut

#loc_left_pair
our $available_fields = {
    'Ticket.Subject'                => 'Subject',
    'Ticket.Status'                 => 'Status',
    'Ticket.OwnerId'                => 'Owner',
    'Ticket.Priority'               => 'Priority',
    'Ticket.InitialPriority'        => 'InitialPriority',
    'Ticket.FinalPriority'          => 'FinalPriority',
    'Ticket.TimeEstimated'          => 'TimeEstimated',
    'Ticket.TimeWorked'             => 'TimeWorked',
    'Ticket.TimeLeft'               => 'TimeLeft',
    'Ticket.QueueId'                => 'Queue',
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


=head2 $empty_is_unchanged_fields

This attribute exists because some RT feature. Some fields listed in this
attribute has Unchanged (i.e. empty) value on web page. So %ARGS entry has empty
value. Fields listed in the attribute will be filled by old value if empty value
will come from web page. 
<Displaying name> => <%ARGS key>

=cut

#loc_left_pair
our $empty_is_unchanged_fields = {
    'Ticket.OwnerId'                => 'Owner',
    'Ticket.Status'                 => 'Status'
};


=head2 $available_ops

Operations available while testing ticket/transaction fields
<Displaying name> => <callback>
Callback receives two params, each can be ARRAY or SCALAR

=cut

#loc_left_pair
our $available_ops = {
    'equal'             => sub { (ref($_[0]) eq 'ARRAY') ? int(grep(/^$_[1]$/, @{$_[0]}))  : int($_[0] eq $_[1]); },
    'not equal'         => sub { (ref($_[0]) eq 'ARRAY') ? int( ! grep(/^$_[1]$/, @{$_[0]})) : int($_[0] ne $_[1]); },
    'match regex'       => sub { (ref($_[0]) eq 'ARRAY') ? int(grep(/$_[1]/, @{$_[0]})) : int($_[0] =~ /$_[1]/); },
    'not match regex'   => sub { (ref($_[0]) eq 'ARRAY') ? int( ! grep(/$_[1]/, @{$_[0]})) : int($_[0] !~ /$_[1]/); },
};


=head2 $available_ops

Aggregation types for "new ticket state" and "checking fields" lists
<Displaying/config value> => <callback>
Callback receives hashref, returning value if check_txn_fields()

=cut

#loc_left_pair
our $aggreg_types = {
    'AND' => sub { 
        int( !! @{$_[0]->{'match'}} && ! @{$_[0]->{'mismatch'}});
    },
    'OR'  => sub { 
        int( !! @{$_[0]->{'match'}});
    }
};


=head1 METHODS

=head2 get_fields_list

Builds full fields list available for checking ($available_fields + CF.*)

Receives

None

Returns 

=over

=item HASHREF {<Displaying name> => <%ARGS key/CF id>}

=back

=cut

sub get_fields_list {
    my $res = {%$available_fields};

    my $cfs = RT::CustomFields->new( RT::SystemUser );
    $cfs->Limit(FIELD => 'id', OPERATOR => '>=', VALUE => '0');
    while (my $cf = $cfs->Next) {
        $res->{'CF.' . $cf->Name} = $cf->id;
    }

    return $res;
}


=head2 fill_ticket_fields

Fills Ticket.* fields by actual values from ticket, "old ticket state"

Receives

=over

=item FIELDS full fields list

=item TICKET ticket obj

=back

Returns

=over

=item HASHREF {<Displaying name> => <value>}. <value> can be scalar or array

=back

=cut

sub fill_ticket_fields {
    my $fields = shift;
    my $ticket = shift;

    my $res = {};
    foreach my $f (grep /^Ticket./, keys %$fields) {
        my $fld = $fields->{$f};
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


=head2 fill_txn_fields

Fills all fields by new value - "new state". Fills $empty_is_unchanged_fields by
new values. Fills some dynamic fields, such as Transaction.Type

Receives

=over

=item FIELDS full fields list

=item TICKET ticket obj

=item ARGSREF $ARGSRef hash from mason

=item CALLBACK_NAME that initiate check (Modify, ModifyAll, Update)

=back

Returns

=over

=item HASHREF {<Displaying name> => <value>}. <value> can be scalar or array

=back

=cut

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

    # "Current" values substitution that rules will be compared with
    #
    # Ticket.OwnerId
    # RT::Nobody means empty value
    $res->{'Ticket.OwnerId'} = '' if ($res->{'Ticket.OwnerId'} eq RT::Nobody->id);

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


=head2 load_config

Reads extension config from database

Receives

None

Returns

=over

=item HASHREF config

=item (undef) if config does not exist

=back

=cut

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


=head2 write_config

Writes config to the database as RT::Attribute entry. Deletes duplicate entries
if necessary

Receives

=over

=item CONFIG

=back

Returns

=over

=item SCALAR

=back

=cut

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

    return $new_cfg->SetContent($config);
}


=head2 check_ticket

Main function that calls from Mason callbacks. Initiate check of current ticket.

Receives

=over

=item TICKET ticket obj

=item ARGSREF $ARGSRef hash

=item CALLBACK_NAME that initiate check (Modify, ModifyAll, Update)

=back

Returns

=over

=item ARRAY What fields in what rules matched. [{name => <rule_name>, fields => ARRAYRef}].

=back

=cut

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
        next unless ($rule->{'enabled'});

        # Ticket match TicketSQL ("Old state")
        my $res = find_ticket($ticket, $rule->{'searchsql'});
        next unless $res;

        my $sf_aggreg_type = $rule->{'sfieldsaggreg'};
        my $rf_aggreg_type = $rule->{'rfieldsaggreg'};

        # Substitute special tags in sfields values
        foreach (@{$rule->{'sfields'}}) {
            if ($_->{'value'} eq '__old__' 
                && exists($ticket_values->{$_->{'field'}})) 
            {
                $_->{'value'} = $ticket_values->{$_->{'field'}} 
            }
        }
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

        # Substitute special tags in rfields values
        foreach (@{$rule->{'rfields'}}) {
            if ($_->{'value'} eq '__old__' 
                && exists($ticket_values->{$_->{'field'}})) 
            {
                $_->{'value'} = $ticket_values->{$_->{'field'}} 
            }
        }
        my $rvalues = {%$ticket_values, %$txn_values};
        $matches = check_txn_fields($rvalues, $rule->{'rfields'});

        die "INTERNAL ERROR: [$PACKAGE] incorrect config in database. Reconfigure please." 
            unless exists($aggreg_types->{$rf_aggreg_type});
        $aggreg_res = $aggreg_types->{$rf_aggreg_type}->($matches);

        my $rule_name = $rule->{'rulename'};
        if ($aggreg_res == 1) {
            push @$errors,
                {
                    name => $rule_name,
                    fields => [@{$matches->{'match'}}]
                };
        }
    }

    return $errors;
}


=head2 check_txn_fields

Checks for matching fields "new ticket state" with config values in specified rule

Receives

=over

=item TXN_FIELDS "new state" fields value

=item CONF_FIELDS config fields

=back

Returns

=over

=item HASH {match => ARRAYREF, mismatch => ARRAYREF, undef => ARRAYREF}. 
undef - field is present in CONF_FIELDS but not in TXN_FIELDS

=back

=cut

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


=head2 find_ticket

Checks whether ticket matches TicketSQL - "old ticket state"

Receives

=over

=item TICKET ticket obj

=item SQL

=back

Returns

=over

=item SCALAR

=back

=cut

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

