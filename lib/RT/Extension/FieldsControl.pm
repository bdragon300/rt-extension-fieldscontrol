package RT::Extension::FieldsControl;

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

RT::Extension::FieldsControl - Conditional ticket/transaction fields validation

=head1 DESCRIPTION

This extension validates ticket and transaction fields on each ticket update 
according on preconfigured rules.

Each validation rule can be applied only to certain tickets using TicketSQL 
selection and/or incoming fields value tests. In applicable rules the incoming 
fields value verifies using control tests. If control tests at least in one 
rule have failed then ticket update aborts and failed rules appears in error 
message (with optional comments).

Incoming fields value can be tested against to string, regular expression or 
current field value.

Thus you have flexible method to control the moving of certain tickets from one 
"state" to another.

Some examples:

=over

=item * make required fields only for certain tickets (e.g. deny close incident 
(ticket in "support" queue with CF.{InteractionType}="Incident") with empty CF.{IncidentReason})

=item * lock "Client" custom role after initial set for all users, only 
management or admins can change them

=item * deny Correspond via web interface in closed tickets

=item * deny simultaneous change CF.{InteractionType} and CF.{GenerateInvoice}. 
Useful when you have "trigger" CF (CF.{GenerateInvoice}) and appropriate Action 
(generate invoice depending on InteractionType). Reason is that RT does not 
guarantee the executing transactions in certain order, so you can get either 
old or new CF.{InteractionType} value when Action executed.

=back

The extension has configuration UI available for users with SuperUser right.

=head1 INSTALLATION

=over

=item C<perl Makefile.PL>

=item C<make>

=item C<make install>

May need root permissions

=item Edit your RT_SiteConfig.pm

If you are using RT 4.2 or greater, add this line:

    Plugin('RT::Extension::FieldsControl');

For RT 3.8 and 4.0, add this line:

    Set(@Plugins, qw(RT::Extension::FieldsControl));

or add C<RT::Extension::FieldsControl> to your existing C<@Plugins> line.

=item After installing you may need to clear Mason cache and restart webserver.

=back

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

Hash describes ticket and transaction fields (besides CustomFields) which user
can set on the update pages.
<Displaying name> => <%ARGS key> 
Some of these fields are set dynamically, e.g. Transaction.Type

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
value. These fields filled by old value if empty value will come from web page. 
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


=head2 $aggreg_types

Aggregation types incoming data tests
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

=head2 get_fields_list() -> \%fields

Build full fields list available in tests ($available_fields + CF.*)

Parameters:

None

Returns:

=over

=item HASHREF {<Displaying name> => <%ARGS key or CF id>}

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


=head2 fill_ticket_fields(\%fields, $ticket) -> \%filled_fields

Fill 'Ticket.*' keys part in given fields with current ticket values

Parameters:

=over

=item fields -- full fields list

=item ticket -- ticket obj

=back

Returns:

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

    # RT::Nobody means empty value for Ticket.OwnerId
    $res->{'Ticket.OwnerId'} = '' if ($res->{'Ticket.OwnerId'} eq RT::Nobody->id);

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


=head2 fill_txn_fields(\%fields, $ticket, \%ARGSRef, $callback_name) -> \%filled_fields

Fill 'Transaction.*', 'CF.*' keys part in given fields with current 
txn/ticket values. Also correct values using $empty_is_unchanged_fields attr.
Also fill dynamic fields ('__Dynamic__').

Parameters:

=over

=item fields -- full fields list

=item ticket -- ticket obj

=item ARGSRef -- $ARGSRef hash from Mason with POST form data

=item callback_name -- page causes the update, comes from Mason callback

=back

Returns:

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
        if (exists($empty_is_unchanged_fields->{$_}) #FIXME: what if field didnt come from page and should not be empty (QueueId on Update.html)
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
        if (exists $ARGSRef->{'UpdateType'}
            && $ARGSRef->{'UpdateType'} eq 'private')
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


=head2 load_config() -> \%config

Load configuration

Parameters:

None

Returns:

=over

=item HASHREF config

=item (undef) if config does not exist

=back

=cut

sub load_config {
    my $attrs = RT::Attributes->new( $RT::SystemUser );
    $attrs->LimitToObject($RT::System);
    $attrs->Limit(FIELD => 'Name', VALUE => 'FieldsControlConfig');
    $attrs->OrderBy(FIELD => 'id', ORDER => 'DESC');

    my $cfg = ($attrs->Count > 0) ? $attrs->First->Content : undef;
    if (ref($cfg) eq 'ARRAY') {
        return $cfg;
    } elsif (defined $cfg) {
        RT::Logger->warning("[$PACKAGE]: Incorrect settings format in database");
    }
    return (undef);
}


=head2 write_config(\%config)

Write configuration. Delete duplicates if necessary

Parameters:

=over

=item config -- configuration HASHREF

=back

Returns:

=over

=item (1, 'Status message') on success and (0, 'Error Message') on failure

=back

=cut

sub write_config {
    my $config = shift;

    die "INTERNAL ERROR: [$PACKAGE]: saving config is not array. Something wrong in index.html"
        if (ref $config ne 'ARRAY');

    my $cfg = RT::Attributes->new( RT::SystemUser );
    $cfg->LimitToObject(RT::System);
    $cfg->OrderBy(FIELD => 'id', ORDER => 'DESC');
    my @all_attrs = $cfg->Named('FieldsControlConfig');
    my $new_cfg = shift @all_attrs if @all_attrs;
    foreach (@all_attrs) {
        $_->Delete;
    }
    unless ($new_cfg) {
        $new_cfg = RT::Attribute->new( RT::SystemUser );
        my $res = $new_cfg->Create(
            Name => 'FieldsControlConfig',
            Description => 'RT::Extension::FieldsControl configuration',
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


=head2 check_ticket($ticket, $ARGSRef, $callback_name) -> \@errors

Check given ticket across all rules. This is main function called from Mason 
callbacks when it triggered.

Parameters:

=over

=item ticket -- ticket obj

=item ARGSRef -- $ARGSRef hash from Mason with POST form data

=item callback_name -- page causes the update, comes from Mason callback

=back

Returns:

=over

=item ARRAY -- Failed rules and fields which caused failure. 
[{name => <rule_name>, fields => ARRAYRef}, ...].

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


=head2 check_txn_fields(\%txn_fields, \@conf_fields) -> \%result_structure

Incoming data testing machinery function. 

Parameters:

=over

=item txn_fields -- incoming fields

=item conf_fields -- tests from config

=back

Returns:

=over

=item HASHREF 
{match => ARRAYREF, mismatch => ARRAYREF, undef => ARRAYREF}. undef contains 
fields present in conf_fields, but not in txn_fields

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


=head2 find_ticket($ticket, $sql) -> 1|0

Check whether given ticket satisfied to given TicketSQL

Parameters:

=over

=item ticket -- ticket obj

=item sql -- TicketSQL expression

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

1;
