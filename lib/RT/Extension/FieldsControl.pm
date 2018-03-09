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
according on preconfigured restrictions.

Each restriction can be applied only to certain tickets using TicketSQL 
selection and/or incoming fields value tests. In applicable restriction 
the incoming fields value verifies using control tests. If control tests at 
least in one restriction have failed then ticket update aborts and failed 
restrictions appears in error message (with optional comments).
Incoming fields value can be tested against to string, regular expression 
or current field value.

Thus you have flexible method to control the moving of certain tickets from 
one "state" to another.

Some examples:

=over

=item * make required fields only for certain tickets (e.g. deny close incident 
(ticket in "support" queue with CF.{InteractionType}="Incident") with empty 
CF.{IncidentReason})

=item * lock "Client" custom role after initial set for all users, only 
management or admins can change them

=item * deny Correspond via web interface in closed tickets

=item * deny simultaneous change CF.{InteractionType} and CF.{GenerateInvoice}. 
Useful when you have "trigger" CF (CF.{GenerateInvoice}) and appropriate 
Action (generate invoice depending on InteractionType). Reason is that RT does 
not guarantee the executing transactions in certain order, so you can get 
either old or new CF.{InteractionType} value when Action executed.

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
Callback receives two params: data (can be SCALAR or ARRAY) and test value
If ARRAY given in data then each element will be tested against test value

=cut

#loc_left_pair
our $available_ops = {
    'equal' =>
        sub {
            (ref($_[0]) eq 'ARRAY')
            ? int(grep(/^$_[1]$/, @{$_[0]}))
            : int($_[0] eq $_[1]);
        },
    'not equal' =>
        sub {
            (ref($_[0]) eq 'ARRAY')
            ? int( ! grep(/^$_[1]$/, @{$_[0]}))
            : int($_[0] ne $_[1]);
        },
    'match regex' =>
        sub {
            (ref($_[0]) eq 'ARRAY')
            ? int(grep(/$_[1]/, @{$_[0]}))
            : int($_[0] =~ /$_[1]/);
        },
    'not match regex' =>
        sub {
            (ref($_[0]) eq 'ARRAY')
            ? int( ! grep(/$_[1]/, @{$_[0]}))
            : int($_[0] !~ /$_[1]/);
        },
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


=head2 $custom_role_subfields

Fields in each custom role member available to test on.
Taken from RT::Tickets::SEARCHABLE_SUBFIELDS
The list must contain only valid users/groups db table fields

=cut

our $custom_role_subfields = [qw(
    EmailAddress Name RealName Nickname Organization Address1 Address2
    City State Zip Country WorkPhone HomePhone MobilePhone PagerPhone id
)];


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
    # CustomFields
    my $cfs = RT::CustomFields->new( RT::SystemUser );
    $cfs->Limit(FIELD => 'id', OPERATOR => '>=', VALUE => '0');
    $cfs->Limit(FIELD => 'lookuptype', OPERATOR => '=', VALUE => 'RT::Queue-RT::Ticket');
    my %cffields = ();
    while (my $cf = $cfs->Next) {
        $cffields{'CF.' . $cf->Name} = $cf->id;
    }

    # CustomRoles
    my $crs = RT::CustomRoles->new( RT::SystemUser );
    $crs->Limit(FIELD => 'disabled', OPERATOR => '=', VALUE => '0');
    my %crfields = ();
    while (my $cr = $crs->Next) {
        # 'Role.Name.<subfield>' => 'Name.<subfield>'
        my %fields = 
            map {
                join('.', ('Role', $cr->Name, $_)) => 'RT::CustomRole-' . $cr->id . '.' . $_
            } @$custom_role_subfields;
        @crfields{keys %fields} = values %fields;
    }

    my %res = (%$available_fields, %cffields, %crfields);
    return \%res;
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

=head2 normalize_object_custom_field_values(CustomField => $cf_obj, Value => $value) -> @values

Split up and normalize custom field value incoming with request if needed. 
Uses when custom field type allows to set multiple values in a single textarea
field. To normalize means to clean redundant spaces, tabs.
Honesty stolen from RT::Interface::Web::_NormalizeObjectCustomFieldValue with 
some changes.

Parameters:

=over

=item $cf_obj -- RT::CustomField object

=item $value -- custom field value comes from page

=back

Returns:

=over

=item ARRAY -- values array

=back

=cut

sub normalize_object_custom_field_values {
    my %args = (
        @_
    );
    my $cf_type = $args{CustomField}->Type;
    my @values  = ();

    if ( ref $args{'Value'} eq 'ARRAY' ) {
        @values = @{ $args{'Value'} };
    } elsif ( $cf_type =~ /text/i ) {    # Both Text and Wikitext
        @values = ( $args{'Value'} );
    } else {
        @values = split /\r*\n/, $args{'Value'}
            if defined $args{'Value'};
    }
    @values = grep length, map {
        s/\r+\n/\n/g;
        s/^\s+//;
        s/\s+$//;
        $_;
        }
        grep defined, @values;

    return @values;
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
        my @arg_val = ();

        # Bulk page sends Add/Delete values (i.e. diff) when other pages send
        # only new values
        if (ucfirst $callback_name eq 'Bulk') {
            my @to_add = 
                map $ARGSRef->{$_},
                grep /^Bulk-Add-CustomField-${cf_id}-Value[^-]?$/, 
                keys %$ARGSRef;
            my @to_delete = 
                map $ARGSRef->{$_},
                grep /^Bulk-Delete-CustomField-${cf_id}-Value[^-]?$/, 
                keys %$ARGSRef;
            next unless (@to_delete || @to_add);  #FIXME: remove
            my $cf = $ticket->LoadCustomFieldByIdentifier( $cf_id );
            next unless $cf->id;
            my $vals_collection = $cf->ValuesForObject($ticket);

            # Apply CF "diff". Leave @arg_val empty if delete all values
            unless ($ARGSRef->{"Bulk-Delete-CustomField-${cf_id}-AllValues"}) {
                @arg_val = map { $_->Content } @{$vals_collection->ItemsArrayRef};
                
                # RT firstly tries to delete values, then add new ones. Do the same
                my @to_delete_n = normalize_object_custom_field_values(
                    CustomField => $cf, 
                    Value => $to_delete[0]
                );
                @arg_val = grep ! ( $_ ~~ @to_delete_n ), @arg_val;
                
                my @to_add_n = normalize_object_custom_field_values(
                    CustomField => $cf, 
                    Value => $to_add[0]
                );  #FIXME: returns undef
                @arg_val = (@arg_val, @to_add_n);

                my $maxv = $cf->MaxValues;
                if ($maxv == 1) {
                    @arg_val = ($arg_val[-1])
                } elsif ($maxv > 1) {
                    @arg_val = grep { defined } @to_add_n[-$maxv..-1];  #FIXME: to_add_n->arg_val
                }
            }

        } else {
            my @raw = 
                map $ARGSRef->{$_},
                grep /^Object-[:\w]+-[0-9]+-CustomField-${cf_id}-Value[^-]?$/, 
                keys %$ARGSRef;
            next unless (@raw);  # No such CF

            my $cf = $ticket->LoadCustomFieldByIdentifier( $cf_id );
            next unless $cf->id;

            @arg_val = normalize_object_custom_field_values(
                CustomField => $cf, 
                Value => $raw[0]
            );
        }

        # Its needed to have at least one element to get op callback worked
        push @arg_val, '' unless (@arg_val);
        $res->{$cf_abbr} = \@arg_val;
    }

    $res->{'Transaction.Type'} = get_transaction_type($callback_name, $ARGSRef);

    $res = {
        %$res, get_txn_customroles($fields, $ticket, $ARGSRef, $callback_name)
    };

    return $res;
}


=head2 get_transaction_type($callback_name, \%ARGSRef) -> \@transaction_type

Return Transaction.Type values array for given data

Parameters:

=over

=item $callback_name

=item $ARGSRef

=back

Returns:

ARRAYREF - Transaction.Type values

=cut

sub get_transaction_type {
    #TODO: add modifypeople
    my $callback_name = shift;
    my $ARGSRef = shift;

    my $res = [];

    if (ucfirst $callback_name eq 'Update') {
        if (exists $ARGSRef->{'UpdateType'}
            && $ARGSRef->{'UpdateType'} eq 'private')
        {
            $res = ['Comment', 'Update', 'Status'];
        } else {
            $res = ['Correspond', 'Update', 'Reply', 'Status'];
        }
    } elsif (ucfirst $callback_name eq 'Modify') {
        $res = ['Set', 'Basics', 'Modify', 'CustomField', 'Status'];
    } elsif (ucfirst $callback_name eq 'ModifyAll') {
        $res = ['Jumbo', 'ModifyAll', 'Status', 'Set'];
    } elsif (ucfirst $callback_name eq 'Bulk') {
        if (exists $ARGSRef->{'UpdateType'}
            && $ARGSRef->{'UpdateType'} eq 'private')
        {
            $res = ['Bulk', 'Comment', 'CustomField', 'Status', 'Set'];
        } else {
            $res = ['Bulk', 'Correspond', 'CustomField', 'Status', 'Set'];
        }
    } elsif (ucfirst $callback_name eq 'ModifyPeople') {
        $res = ['ModifyPeople'];
    }

    return $res;
}


=head2 get_txn_customroles(\%fields, $ticket, \%ARGSRef, $callback_name) -> %customroles

Return Role.* fields came with request in ARGSRef

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

sub get_txn_customroles {
    my $fields = shift;
    my $ticket = shift;
    my $ARGSRef = shift;
    my $callback_name = shift;

    my %res;
    my @fields = grep /^Role\./, keys %$fields;

    # make unique
    my $p = '';
    my @customroles = 
        grep { ($p eq $_) ? undef : ($p = $_) } 
        sort 
        map /^Role\.(.*)\.\w+$/, 
        @fields; 
    foreach my $crname (@customroles) {
        # RT::CustomRole-id
        my ($crdbname) = $fields->{'Role.' . $crname . '.id'} =~ /^([^.]+)\./;  
        my $crgrp = $ticket->RoleGroup($crdbname);
        next unless $crgrp->id;

        my @add_ids = (); my @delete_ids = ();
        my $single_value_cr = 0;
;
        foreach my $k (keys %$ARGSRef) {
            # ModifyPeople.html, add principal
            if ($k =~ /^Ticket-AddWatcher-Principal-(\d+)$/) {
                push @add_ids, "$1" if $ARGSRef->{$k} eq $crdbname;

            # ModifyPeople.html, delete principal
            } elsif ($k =~ /^Ticket-DeleteWatcher-Type-${crdbname}-Principal-(\d+)$/ ) {
                push @delete_ids, "$1" if $ARGSRef->{$k};

            # ModifyPeople.html, add user
            } elsif ($k =~ /^WatcherTypeEmail(\d+)$/ ) {
                next if ($ARGSRef->{$k} ne $crdbname);

                my $email = $ARGSRef->{"WatcherAddressEmail$1"};
                my $user = load_custom_role_user($email);
                next unless $user->id;

                push @add_ids, $user->PrincipalObj->id;

            # Bulk.html, delete/add user
            } elsif ($k =~ /^((Add|Delete)${crdbname})$/) {
                my $name = $ARGSRef->{$k};
                my $user = load_custom_role_user($name);
                next unless $user->id;

                if ($k =~ /^Delete/) {
                    push @delete_ids, $user->PrincipalObj->id;
                } elsif ($k =~ /^Add/) {
                    push @add_ids, $user->PrincipalObj->id;
                }

            # ModifyPeople.html, Bulk.html, set single-user custom roles
            } elsif ($k eq $crdbname) {
                my $name = $ARGSRef->{$k};
                $single_value_cr = 1;  # TODO: rely on cr is_single prop

                if ($name eq '') {  # Nobody
                    @add_ids = ();
                } else {
                    my $user = load_custom_role_user($name);
                    next unless $user->id;

                    @add_ids = ($user->PrincipalObj->id);
                    last;
                }
            }
        }

        my $ticket_principals = $crgrp->MembersObj;
        my @members = ();
        if ( ! $single_value_cr) {
            @members = 
                grep { ! ( $_->id ~~ @delete_ids ) }
                map { $_->MemberObj->Object }
                @{$ticket_principals->ItemsArrayRef};
        }
        
        if (@add_ids) {
            my $add_principals = RT::Principals->new( RT::SystemUser );
            $add_principals->Limit(
                FIELD => 'id', 
                OPERATOR => 'IN', 
                VALUE => \@add_ids
            );
            push @members, 
                map { $_->Object }
                @{$add_principals->ItemsArrayRef};
        }

        # Fill out subfields
        my %crvals = ();
        foreach my $subf (@$custom_role_subfields) {
            my $k = "Role.${crname}.${subf}";
            $crvals{$k} = [];

            foreach my $member (@members) {  # TODO: nobody means empty
                my $val = undef;

                # RT::Group has only limited subfields
                next if (ref($member) eq 'RT::Group' 
                         && $subf ne 'Name' 
                         && $subf ne 'id');

                $val = $member->_Value($subf) // '';
                push @{$crvals{$k}}, $val;
            }
            push @{$crvals{$k}}, '' unless @{$crvals{$k}};
        }
        @res{keys %crvals} = values %crvals;

        undef @members;
    }

    return %res;
}


=head2 load_custom_role_user($name) -> $user_obj

Loads RT::User by given name. Name can be id, name, email

Parameters:

=over

=item $name -- id, name, email of loaded RT::User

=back

Return:

=over

=item $user_obj -- loaded RT::User. Empty object if fail

=back

=cut

sub load_custom_role_user {
    my $name = shift;
    my $user = RT::User->new(RT->SystemUser);

    if ($name =~ /@/) {
        $user->LoadByEmail( $name );
    } else {
        $user->Load( $name );
    }

    return $user;
}


=head2 load_config() -> %config

Load configuration

Parameters:

None

Returns:

=over

=item HASH

=back

=cut

sub load_config {
    my $attrs = RT::Attributes->new( $RT::SystemUser );
    $attrs->LimitToObject($RT::System);
    $attrs->Limit(FIELD => 'Name', VALUE => 'FieldsControlRestriction');
    $attrs->OrderBy(FIELD => 'id', ORDER => 'ASC');

    my %config;

    my %items;
    while (my $attr = $attrs->Next) {
        $items{$attr->id} = $attr->Content;
    }
    $config{restrictions} = \%items;

    return %config;
}

=head2 _find_attribute_by_id($id) -> $attribute_obj

Loads RT::Attribute with given id

Parameters:

=over

=item id

=back

Return:

RT::Attribute object. If unable to load then empty object returned

=cut

sub _find_attribute_by_id {
    my $id = shift;

    my $attrs = RT::Attributes->new( RT::SystemUser );
    $attrs->LimitToObject(RT::System);
    $attrs->Limit(FIELD => 'Name', VALUE => 'FieldsControlRestriction');
    $attrs->Limit(FIELD => 'id', VALUE => ($id || 0));

    return $attrs->First || RT::Attribute->new( RT::SystemUser );
}


=head2 write_config(create_r => [], update_r => {}, delete_r => {})

Write configuration

Parameters:

=over

=item create_r -- Optional. ARRAYREF, restrictions to be created

=item update_r -- Optional. HASHREF, restrictions to be updated

=item delete_r -- Optional. HASHREF, restrictions to be deleted

=back

Returns:

=over

=item 1 on success, 0 when some errors happened

=back

=cut

sub write_config {
    my %args = (
        create_r => [],
        update_r => {},
        delete_r => {},
        @_
    );
    my $success = 1;

    foreach my $r (@{$args{create_r}}) {
        my $record = RT::Attribute->new( RT::SystemUser );
        $record->Create(
            Name => 'FieldsControlRestriction',
            Description => 'RT::Extension::FieldsControl restriction',
            ContentType => 'storable',
            Object => RT::System
        );
        my ($res, $msg) = $record->SetContent($r);

        unless ($res) {
            RT::Logger->error(
                "[$PACKAGE]: Unable to create RT::Attribute: $msg"
            );
            $success = 0;
        }
    }

    foreach my $id (keys %{$args{update_r}}) {
        my $record = _find_attribute_by_id($id);
        if ($record->id) {
            $record->SetContent($args{update_r}->{$id});
        } else {
            RT::Logger->error(
                "[$PACKAGE]: Unable to update RT::Attribute id=" . $id
            );
            $success = 0;
        }
    }

    foreach my $id (keys %{$args{delete_r}}) {
        my $record = _find_attribute_by_id($id);
        if ($record->id) {
            $record->Delete;
        } else {
            RT::Logger->error("[$PACKAGE]: Unable to delete non-existent " .
                "RT::Attribute id=" . $id);
            $success = 0;
        }
    }
    
    RT::Logger->info("[$PACKAGE]: Config written successfull") if ($success);
    return $success;
}


=head2 check_ticket($ticket, $ARGSRef, $callback_name) -> \@errors

Check given ticket across all rules. This is main function called from Mason 
callbacks when it triggered.

Returns hash. 'errors' item contains failed rules and fields. Each rule hash
takes from config.
'tests_refer_to_ticket' set to 1 if some of tests in rules (either in 
"Applies to" or "Fail if") refer to the current ticket field value. 
Intended to avoid situation when the ticket was changed by someone after page 
load, so __old__ would refer to the changed value not the one which user
sees. As a result the test "CF.1 equal __old__" will always give false even 
nothing changed on the page. Solution is to reload the page with changes losing.

Parameters:

=over

=item ticket -- ticket obj

=item ARGSRef -- $ARGSRef hash from Mason with POST form data

=item callback_name -- page causes the update, comes from Mason callback

=back

Returns:

=over

=item HASHREF -- 
{errors => [$rule1, \@failed_fields1, ...], tests_refer_to_ticket => 1|0}

=back

=cut

sub check_ticket {

    my $ticket = shift;
    my $ARGSRef = shift;
    my $callback_name = shift;
    my $errors = {
        errors => [],
        tests_refer_to_ticket => 0
    };

    my %config = load_config;
    my %restrictions = %{$config{restrictions}};
    return $errors unless %restrictions; # No rules

    my $fields = get_fields_list;
    my $txn_values = fill_txn_fields($fields, $ticket, $ARGSRef, $callback_name);
    my $ticket_values = fill_ticket_fields($fields, $ticket);

    foreach my $rule (values %restrictions) {
        next unless ($rule->{'enabled'});

        # Ticket match TicketSQL ("Old state")
        my $res = find_ticket($ticket, $rule->{'searchsql'});
        next unless $res;

        my $sf_aggreg_type = $rule->{'sfieldsaggreg'};
        my $rf_aggreg_type = $rule->{'rfieldsaggreg'};

        # Substitute special tags in sfields values
        foreach (@{$rule->{'sfields'}}) {
            if ($_->{'value'} eq '__old__') {
                if (exists($ticket_values->{$_->{'field'}})) {
                    $_->{'value'} = $ticket_values->{$_->{'field'}};
                }
                $errors->{tests_refer_to_ticket} = 1;
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
            if ($_->{'value'} eq '__old__') {
                if (exists($ticket_values->{$_->{'field'}})) {
                    $_->{'value'} = $ticket_values->{$_->{'field'}};
                }
                $errors->{tests_refer_to_ticket} = 1;
            }
        }
        my $rvalues = {%$ticket_values, %$txn_values};
        $matches = check_txn_fields($rvalues, $rule->{'rfields'});

        die "INTERNAL ERROR: [$PACKAGE] incorrect config in database. Reconfigure please." 
            unless exists($aggreg_types->{$rf_aggreg_type});
        $aggreg_res = $aggreg_types->{$rf_aggreg_type}->($matches);

        if ($aggreg_res == 1) {
            push @{$errors->{errors}}, $rule, [@{$matches->{'match'}}];
            my $tid = $ticket->id;
            RT::Logger->info(
                "[$PACKAGE]: Ticket #$tid, restriction '" . $rule->{'rulename'}.
                "' on page '$callback_name' failed with fields: " .
                join ', ', @{$matches->{'match'}}
            );
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
