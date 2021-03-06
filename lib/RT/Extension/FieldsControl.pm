package RT::Extension::FieldsControl;

use 5.10.1;
use strict;
use warnings;
use RT::Tickets;
use RT::Attributes;
use RT::CustomField;
use Data::Dumper qw(Dumper);
use experimental 'smartmatch';

our $VERSION = '0.1';
our $PACKAGE = __PACKAGE__;

=head1 NAME

RT::Extension::FieldsControl - Conditional user input validation

=head1 DESCRIPTION

This extension validates ticket and transaction fields on each ticket update 
according on preconfigured restrictions. In few words it controls user input 
and prevents to get into a forbidden ticket state.
Ticket fields, transaction fields, custom fields, custom role members can be 
tested. The extension has Admin UI.

Each restriction can be applied only to certain tickets using TicketSQL 
selection and/or "new state" tests. Extension verifies user input using 
control tests only using applicable restrictions. If control tests at least 
in one restriction have failed then ticket update aborts and failed 
restrictions appears in error message (with optional comments). Such checks 
performed at all modify pages.

Incoming data can be tested against to string, regular expression or current 
field value.

New state for every field means its value after successfull update. 
For single-value fields it means just new value. For multi-value fields it 
means current values + user input.

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

The configuration UI available for users with SuperUser right.

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
<Displaying name> => <%ARGS keys>

=cut

#loc_left_pair
our $available_fields = {
    'Ticket.Subject'                => 'Subject',
    'Ticket.Status'                 => 'Status',
    'Ticket.Priority'               => 'Priority',
    'Ticket.InitialPriority'        => 'InitialPriority',
    'Ticket.FinalPriority'          => 'FinalPriority',
    'Ticket.TimeEstimated'          => 'TimeEstimated',
    'Ticket.TimeWorked'             => 'TimeWorked',
    'Ticket.TimeLeft'               => 'TimeLeft',
    'Ticket.QueueId'                => 'Queue',
    'Ticket.Last Contact'           => 'Told_Date',
    'Ticket.Starts'                 => 'Starts_Date',
    'Ticket.Started'                => 'Started_Date',
    'Ticket.Due'                    => 'Due_Date',
    'Transaction.Attach'            => 'Attach',
    'Transaction.Content'           => 'Content',
    'Transaction.Worked'            => 'UpdateTimeWorked',
    'Transaction.Content'           => 'UpdateContent',
    'Transaction.Subject'           => 'UpdateSubject',
    'Transaction.One-time-CC'       => 'UpdateCc',
    'Transaction.One-time-Bcc'      => 'UpdateBcc',
    'Transaction.Sign'              => 'Sign',
    'Transaction.Encrypt'           => 'Encrypt',
    'Transaction.Comment?'          => '__Dynamic__',
    'Transaction.Correspond?'       => '__Dynamic__'
};


my @datetime_fields = qw/Told_Date Starts_Date Started_Date Due_Date/;


use constant DATETIME_NOT_SET => '1970-01-01 00:00:00';


=head2 $empty_is_unchanged_fields

This attribute exists because some RT feature. Some fields listed in this
attribute has Unchanged (i.e. empty) value on web page. So %ARGS entry has empty
value. These fields filled by old value if empty value will come from web page. 
<Displaying name> => <%ARGS key>

=cut

#loc_left_pair
our $empty_is_unchanged_fields = {
    'Ticket.Status'                 => 'Status'
};


=head2 $available_ops

Operations available while testing ticket/transaction fields
<Displaying name> => <callback>
Callbacks takes two params:

1. actual_value -- ARRAYREF|SCALAR, actual txn/ticket field value

2. conf_value -- ARRAYREF|SCALAR, restriction value that actual values 
compares with. Can be ARRAYRef when e.g. when '__old__' tag specified

=cut

#loc_left_pair
our $available_ops = {
    'equal' =>
        sub {
            my ($a, $b) = @_;
            if (ref($_[0]) eq 'ARRAY' && ref($_[1]) eq 'ARRAY') {
                $a = [sort(@$a)]; $b = [sort(@$b)];
            }
            $b ~~ $a;
        },
    'not equal' =>
        sub {
            my ($a, $b) = @_;
            if (ref($_[0]) eq 'ARRAY' && ref($_[1]) eq 'ARRAY') {
                $a = [sort(@$a)]; $b = [sort(@$b)];
            }
            ! ($b ~~ $a);
        },
    'match regex' =>
        sub {
            return '' if (ref($_[1]) eq 'ARRAY');  # Must be regex only
            return $_[0] ~~ /$_[1]/;
        },
    'not match regex' =>
        sub {
            return '' if (ref($_[1]) eq 'ARRAY');  # Must be regex only
            return ! ($_[0] ~~ /$_[1]/);
        },
    'more than' => 
        sub {
            my ($a, $b) = @_;
            (ref($a) eq 'ARRAY')
            ? int(grep { $_ gt $b } @$a)
            : int($a gt $b);
        },
    'less than' =>
        sub {
            my ($a, $b) = @_;
            (ref($a) eq 'ARRAY')
            ? int(grep { $_ lt $b } @$a)
            : int($a lt $b);
        }
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


=head2 @standard_ticket_roles

Standard ticket roles such as Owner, Requestor, etc.

=cut

our @standard_ticket_roles = qw/Owner Requestor AdminCc Cc/;


=head2 $custom_role_subfields

Fields in each custom role member available to test on.
Taken from RT::Tickets::SEARCHABLE_SUBFIELDS
The list must contain only valid users/groups db table fields

=cut

our $custom_role_subfields = [qw(
    EmailAddress Name RealName Nickname Organization Address1 Address2
    City State Zip Country WorkPhone HomePhone MobilePhone PagerPhone id IsUser?
    IsGroup?
)];


# All pages we spy on
our @spy_pages = qw(Create Update Modify ModifyAll ModifyPeople Bulk 
    ModifyDates m/ticket/reply m/ticket/create);

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
        # 'Role.Name.<subfield>' => 'RT::CustomRole-id.<subfield>'
        my %fields = 
            map {
                join('.', ('Role', $cr->Name, $_)) => 'RT::CustomRole-' . $cr->id
            } @$custom_role_subfields;
        @crfields{keys %fields} = values %fields;
    }
    foreach my $role (@standard_ticket_roles) {
        # 'Role.Name.<subfield>' => 'Name'
        my %fields = 
            map {
                join('.', ('Role', $role, $_)) => $role
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
        $fld = $fld =~ s/^(.*)_Date/$1/gr;  # / Date fields names has '_Date' postfix in %ARGS
        $res->{$f} = $ticket->_Value($fld);

        # Unixtime 0 means 'Not set' for datetime fields
        if ($f ~~ @datetime_fields && $res->{$f} eq DATETIME_NOT_SET) {
            $res->{$f} = '';
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
        next unless (defined $ARGSRef->{$fields->{$_}});

        $res->{$_} = $ARGSRef->{$fields->{$_}};

        # If empty then retrieve it from TicketObj
        if (exists($empty_is_unchanged_fields->{$_})
            && defined($res->{$_})
            && ($res->{$_} eq '')
            && $ticket)
        {
            $res->{$_} = $ticket->_Value($empty_is_unchanged_fields->{$_});
        }

        # Unixtime 0 means 'Not set' for datetime fields
        if ($_ ~~ @datetime_fields && $res->{$_} eq DATETIME_NOT_SET) {
            $res->{$_} = '';
        }
    }

    # "Current" values substitution that rules will be compared with
    #

    foreach (grep /^Transaction./, keys %$fields) {
        next unless (defined $ARGSRef->{$fields->{$_}});

        $res->{$_} = $ARGSRef->{$fields->{$_}};
    }

    # Comment?, Correspond?
    $res->{'Transaction.Comment?'} = '';
    $res->{'Transaction.Correspond?'} = '';
    if (ucfirst $callback_name eq 'Update'
        && exists($ARGSRef->{'UpdateType'})) {
        $res->{'Transaction.Comment?'} = $ARGSRef->{'UpdateType'} eq 'private';
        $res->{'Transaction.Correspond?'} = $ARGSRef->{'UpdateType'} eq 'response';
    }

    $res = {
        %$res, 
        fill_txn_customfields($fields, $ticket, $ARGSRef, $callback_name)
    };

    return $res;
}


=head2 fill_txn_customfields(\%fields, $ticket, \%ARGSRef, $callback_name) -> %customfields

Return CF.* fields came with request in ARGSRef

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

sub fill_txn_customfields {
    my $fields = shift;
    my $ticket = shift;
    my $ARGSRef = shift;
    my $callback_name = shift;

    my %res;

    my $cfs;
    if ($ticket) {
        $cfs = $ticket->CustomFields;
    } else {
        $cfs = RT::CustomFields->new( RT::SystemUser );
        $cfs->UnLimit();
    }
    
    while (my $cf = $cfs->Next) {
        my $print_name = 'CF.' . $cf->Name;
        next unless (exists $fields->{$print_name});

        my $vals_collection = ($ticket) 
            ? $cf->ValuesForObject($ticket) 
            : RT::ObjectCustomFieldValues->new( RT::SystemUser );

        my $cf_id = $cf->id;
        my @txn_vals = ();

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

            # Apply CF "diff". Leave @arg_val empty if delete all values
            unless ($ARGSRef->{"Bulk-Delete-CustomField-${cf_id}-AllValues"}) {
                @txn_vals = map { $_->Content } @{$vals_collection->ItemsArrayRef};
                
                # RT firstly tries to delete values, then add new ones. Do the same
                my @to_delete_n = normalize_object_custom_field_values(
                    CustomField => $cf, 
                    Value => $to_delete[0]
                );
                @txn_vals = grep ! ( $_ ~~ @to_delete_n ), @txn_vals;
                
                my @to_add_n = normalize_object_custom_field_values(
                    CustomField => $cf, 
                    Value => $to_add[0]
                );
                push @txn_vals, @to_add_n;
            }

            # Its needed to have at least one element to get op callback worked
            push @txn_vals, '' unless (@txn_vals);

        } else {
            my @raw = 
                map $ARGSRef->{$_},
                grep /^Object-[:\w]+-[0-9]*-CustomField-${cf_id}-Value[^-]?$/, 
                keys %$ARGSRef;
            if (@raw) {
                @txn_vals = normalize_object_custom_field_values(
                    CustomField => $cf, 
                    Value => $raw[0]
                );

                # Its needed to have at least one element to get op callback worked
                push @txn_vals, '' unless (@txn_vals);
            }
        }

        my $res_vals;
        if (@txn_vals) {
            $res_vals = \@txn_vals;
        } else {
            # If CF has select type and predefined values dependent on another
            # CF and user has chosen its value so current CF has no values at 
            # all and absent in ARGSRef, despite it appear on Create.html page
            # We only guess its existence only by '...-Magic' ARGSRef key 
            unless ($ticket) {
                next unless (
                    grep /^Object-[:\w]+-[0-9]*-CustomField-${cf_id}-Values-Magic$/, 
                    keys %$ARGSRef
                );
            }
            next unless ($ticket); # Skip if not CF on Create.html

            my @v = ();
            while (my $v = $vals_collection->Next) {
                push @v, $v->Content;
            }
            $res_vals = \@v;

            # Its needed to have at least one element to get op callback worked
            push @$res_vals, '' unless (@v);
        }

        my $maxv = $cf->MaxValues;
        if ($maxv == 1) {
            $res_vals = @$res_vals[0];
        } elsif ($maxv > 1) {
            $res_vals = [grep { defined } @$res_vals[-$maxv..-1]];
        }

        $res{$print_name} = $res_vals;
    }

    return %res;
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

    return grep defined, @values;
}


=head2 fill_txn_roles(\%fields, $ticket, \%ARGSRef, $callback_name) -> %customroles

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

sub fill_txn_roles {
    my $fields = shift;
    my $ticket = shift;
    my $ARGSRef = shift;
    my $callback_name = shift;

    my %res;

    my $queueobj;
    if ($ticket) {
        $queueobj = $ticket->QueueObj;
    } elsif ($ARGSRef->{Queue}) {
        $queueobj = RT::Queue->new( RT::SystemUser );
        $queueobj->Load($ARGSRef->{Queue});
    }
    unless ($queueobj && $queueobj->id) {
        RT::Logger->error(
            "[$PACKAGE]: Fatal: unable to figure out ticket's queue. Skip check roles"
        );
        return %res;
    }

    # Collect CustomRoles' ids related to queue
    my @queue_role_ids;
    my $queue_roles = $queueobj->CustomRoles;
    while (my $role = $queue_roles->Next) {
        push @queue_role_ids, $role->id;
    }
    undef $queue_roles;
    undef $queueobj;

    # CustomRoleName => RT::CustomRole-id
    my %roles = 
        map { /^Role\.(.*)\..+$/ => $fields->{$_} } 
        grep { /^Role\./ }
        keys %$fields;

    foreach my $rolename (keys %roles) {
        my $roledbname = $roles{$rolename};

        # Skip role does not applied to queue
        my ($crid) = $roledbname =~ /^RT::CustomRole-(.+)/;
        next if ($crid && ! ($crid ~~ @queue_role_ids));

        my $rolegrp;
        if ($ticket) {  # Skip load role if Create page caused check
            $rolegrp = $ticket->RoleGroup($roledbname);
            next unless $rolegrp->id;
        }

        # If role is multi-value then firstly retrieve current principals and 
        # then apply changes (add/remove principals)
        # If role is single-value CustomRole or such as Owner then simply
        # replace old principal with new one
        # Create.html passes only new principal values
        my @add_ids = (); my @delete_ids = (); my @add_principals = ();
        my $ticket_principals = 1;  # Append current ticket principals to a result

        foreach my $k (keys %$ARGSRef) {
            # ModifyPeople.html, add principal
            if ($k =~ /^Ticket-AddWatcher-Principal-(\d+)$/) {
                push @add_ids, "$1" if $ARGSRef->{$k} eq $roledbname;

            # ModifyPeople.html, delete principal
            } elsif ($k =~ /^Ticket-DeleteWatcher-Type-${roledbname}-Principal-(\d+)$/ ) {
                push @delete_ids, "$1" if $ARGSRef->{$k};

            # ModifyPeople.html, add user
            } elsif ($k =~ /^WatcherTypeEmail(\d+)$/ ) {
                next if ($ARGSRef->{$k} ne $roledbname);

                my $email = $ARGSRef->{"WatcherAddressEmail$1"};
                my $user = load_custom_role_user($email);
                next unless $user->id;

                push @add_principals, $user->PrincipalObj;

            # Bulk.html, delete/add user
            } elsif ($k =~ /^((Add|Delete)${roledbname})$/) {
                my $name = $ARGSRef->{$k};
                my $user = load_custom_role_user($name);
                next unless $user->id;

                if ($k =~ /^Delete/) {
                    push @delete_ids, $user->PrincipalObj->id;
                } elsif ($k =~ /^Add/) {
                    push @add_principals, $user->PrincipalObj;
                }

            # Create.html, ModifyPeople.html, Bulk.html, set single-user custom roles
            # Create.html passes also 'Requestors' key with comma-separated principals list
            } elsif ($k =~ /^${roledbname}s?$/) {
                $ticket_principals = 0;  # Replace current ticket principals on new ones
                @add_ids = ();
                my $name = $ARGSRef->{$k};

                if ($name eq '') {
                    # Nobody if custom role
                    @add_principals = ();
                    # 'Unchanged' if Owner
                    $ticket_principals = 1 if ($roledbname eq 'Owner');
                } elsif ($roledbname eq 'Owner' && $name eq RT::Nobody->id) {
                    @add_principals = ();
                } else {
                    # ModifyAll.html exclusion, it has two Owner selects
                    # Owner comes as array. 
                    # Otherwise ignore change
                    if (ref $name eq 'ARRAY' && $callback_name eq 'ModifyAll') {
                        my $owner = $ticket->OwnerObj;
                        @add_ids = grep { $_ ne $owner->id }
                            grep { defined && /^\d+$/ }
                            @$name;
                        splice @add_ids, 1;
                        @add_ids = ($owner->id) unless @add_ids;
                    # There is possible to set several comma-separated Requestors
                    # on Create.html
                    } else {
                        my @names = split /,/, $name;  # Create.html
                        while (my $name = shift @names) {
                            $name = $name =~ s/^\s+|\s+$//gr;  # / trim
                            my $user = load_custom_role_user($name);
                            next unless $user->id;

                            push @add_principals, $user->PrincipalObj;
                        }
                    }
                }

                last;
            }
        }

        my @members = ();
        
        # RT firstly excludes deleting principals from result, then appends 
        # adding ones. Do the same.
        if ($ticket && $ticket_principals) {
            my $ticket_principals = $rolegrp->MembersObj;
            @members = 
                grep { ! ( $_->id ~~ @delete_ids ) }
                map { $_->MemberObj->Object }
                @{$ticket_principals->ItemsArrayRef};
        }

        push @members, map { $_->Object } @add_principals;
        
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
        my $subfields_data = fill_role_subfields($rolename, \@members, $custom_role_subfields);
        @res{keys %$subfields_data} = values %$subfields_data;

        undef @members;
        undef @add_principals;
    }

    return %res;
}


=head2 fill_role_subfields($rolename, \@members, \@subfields_list) -> \%subfields_data

Takes role and its members and makes hash suitable for compare. Such as:
Role.role1.id => [<ids>], Role.role1.name => [<names>] and so on

Parameters:

=over

=item $rolename - Printable role name. Substitutes to result keys

=item \@members - ARRAYREF with role members, RT::User or RT::Group objects

=item \@subfields_list - ARRAYREF with subfields list

=back

Return:

HASHREF with filled data

=cut

sub fill_role_subfields {
    my $rolename = shift;
    my $members = shift;
    my $subfields = shift;

    my %res = ();
    foreach my $subf (@$subfields) {
        my $k = "Role.${rolename}.${subf}";
        $res{$k} = [];

        foreach my $member (@$members) {
            my $val = undef;

            if ($subf eq 'IsUser?') {
                $val = ref($member) eq 'RT::User';
            } elsif ($subf eq 'IsGroup?') {
                $val = ref($member) eq 'RT::Group';
            } else {
                # RT::Group has only Name, id subfields
                next if (ref($member) eq 'RT::Group' 
                         && $subf ne 'Name' 
                         && $subf ne 'id');
                $val = $member->_Value($subf) // '';
            }
            
            push @{$res{$k}}, $val;
        }
        push @{$res{$k}}, '' unless @{$res{$k}};
    }

    return \%res;
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
    my %restrictions = %{$config{restrictions}};  # RT::Attribute id => Content
    return $errors unless %restrictions; # No rules

    # Work only with fields that actually used in restrictions
    my $all_fields = get_fields_list;
    my %fields = 
        map { $_->{field} => $all_fields->{$_->{field}} }
        map { (@{$_->{rfields}}, @{$_->{sfields}}) }
        values %restrictions;

    # We always need queue to know whether or not to apply restriction
    $fields{'Ticket.QueueId'} = $all_fields->{'Ticket.QueueId'};

    my $txn_values = fill_txn_fields(\%fields, $ticket, $ARGSRef, $callback_name);
    my $ticket_values = ($ticket) ? fill_ticket_fields(\%fields, $ticket) : {};

    # Use roles only when user can change them on, E.g. Modify.html
    my %roles_values = fill_txn_roles(\%fields, $ticket, $ARGSRef, $callback_name);

    my %all_values = (%$ticket_values, %roles_values, %$txn_values);

    foreach my $rule (values %restrictions) {
        next unless ($rule->{'enabled'});
        next unless ($callback_name ~~ $rule->{apply_pages});  # Not applied on page caused request

        my $queueid = $txn_values->{'Ticket.QueueId'} // $ticket_values->{'Ticket.QueueId'};
        next unless (
            ! exists ($rule->{applies})
            || $rule->{applies}->{global} 
            || $queueid ~~ $rule->{applies}->{queues}
        );

        # Ticket match TicketSQL ("Old state")
        my $ticketsql_ok = 1;
        if ($ticket && $rule->{'searchsql'}) {
            $ticketsql_ok = find_ticket($ticket, $rule->{'searchsql'});
        }
        next unless $ticketsql_ok;

        my $sf_aggreg_type = $rule->{'sfieldsaggreg'};
        my $rf_aggreg_type = $rule->{'rfieldsaggreg'};

        # Substitute special tags in sfields values
        foreach (@{$rule->{'sfields'}}) {
            $errors->{tests_refer_to_ticket} = 1 
                if ($_->{'value'} eq '__old__');
            
            my $substituted = substitute_special(
                test => $_, fields => \%fields, ticket => $ticket,
                ticket_values => $ticket_values
            );
            $_->{'value'} = $substituted if (defined $substituted);
        }
        my $matches = check_txn_fields(\%all_values, $rule->{'sfields'});
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
            $errors->{tests_refer_to_ticket} = 1 
                if ($_->{'value'} eq '__old__');

            my $substituted = substitute_special(
                test => $_, fields => \%fields, ticket => $ticket,
                ticket_values => $ticket_values
            );
            $_->{'value'} = $substituted if (defined $substituted);
        }
        $matches = check_txn_fields(\%all_values, $rule->{'rfields'});
        die "INTERNAL ERROR: [$PACKAGE] incorrect config in database. Reconfigure please." 
            unless exists($aggreg_types->{$rf_aggreg_type});
        $aggreg_res = $aggreg_types->{$rf_aggreg_type}->($matches);

        if ($aggreg_res == 1) {
            push @{$errors->{errors}}, $rule, [@{$matches->{'match'}}];
            my $tid = ($ticket) ? $ticket->id : 'new';
            RT::Logger->info(
                "[$PACKAGE]: Ticket #$tid, restriction '" . $rule->{'rulename'}.
                "' on page '$callback_name' failed with fields: " .
                join ', ', @{$matches->{'match'}}
            );
        }
    }

    return $errors;
}


=head2 substitute_special(%args) -> $value

Substitutes special tags in test on actual value suitable to be compared later

Parameters:

See function code

Return:

Substituted value or undef if nothing to substitute

=cut

sub substitute_special {
    # All args are required
    my %args = (
        test => undef,
        fields => undef,
        ticket => undef,
        ticket_values => undef,
        @_
    );
    my $test = $args{test};
    my $ticket = $args{ticket};

    if ($test->{'value'} eq '__old__') {
        if (exists($args{ticket_values}->{$test->{'field'}})) {
            return $args{ticket_values}->{$test->{'field'}};
        } elsif ($test->{'field'} =~ /^CF\.(.*)$/) {
            return '' unless ($ticket);

            my $cfid = $args{fields}->{$test->{'field'}};
            my $cfvals = $ticket->CustomFieldValues($cfid);
            my @cfvals = map { $_->Content } @{$cfvals->ItemsArrayRef};
            undef $cfvals;

            push @cfvals, '' unless (@cfvals);

            return (scalar(@cfvals) == 1) ? $cfvals[0] : \@cfvals;
        } elsif ($test->{'field'} =~ /^Role\.([^.]+)\..*$/) {
            return '' unless ($ticket);

            my $rolename = $1;
            my $sysname = $args{fields}->{$test->{'field'}};
            my $rolegrp = $ticket->RoleGroup($sysname);
            return '' unless ($rolegrp->id);

            my @members = 
                map { $_->MemberObj->Object }
                @{$rolegrp->MembersObj->ItemsArrayRef};
            my $sf = fill_role_subfields(
                $rolename, \@members, $custom_role_subfields
            );
            return $sf->{$test->{'field'}};
        } else {
            return '';
        }
    } elsif ($test->{'value'} =~ /^__(.*)__$/) {  # Date expression
        my $date = RT::Date->new( RT::SystemUser );
        $date->Set( Format => 'unknown', Value => $1 );
        return $date->ISO;
    }

    return (undef);
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
