# Summary

RT::Extension::FieldsControl -- Conditional user input validation

# Description

This extension validates ticket and transaction fields on each ticket update according on preconfigured restrictions. In few words it controls user input and prevents to get into a forbidden ticket state.
Ticket fields, transaction fields, custom fields, custom role members can be tested. The extension has Admin UI.

Each restriction can be applied only to certain tickets using preliminary TicketSQL selection and/or "new state" tests. Extension verifies user input using control tests only using applicable restrictions. If control tests at least in one restriction have failed then ticket update aborts and failed restrictions appears in error message (with optional comments). Such checks performed at all modify pages.
Incoming data can be tested against to string, regular expression or current field value.

New state for every field means its value after successfull update. For single-value fields it means just new value. For multi-value fields it means current values + user input.

Some examples:
* make required fields only for certain tickets (e.g. deny close incident (ticket in "support" queue with CF.{InteractionType}="incident") with empty Priority)
* lock "Client" custom role after initial set
* deny Correspond via web interface on closed tickets
* deny simultaneous change CF.{InteractionType} and CF.{GenerateInvoice}. Useful when you have "trigger" CF (CF.{GenerateInvoice}) and appropriate Action (generate invoice depending on InteractionType). Reason is that RT does not guarantee the executing transactions in certain order, so you can get either old or new CF.{InteractionType} value when Action executed.

The configuration UI available for users with SuperUser right.

Here how its look like. Restriction list:

![Restriction list page](screenshots/restriction_list.png)

Let's take the first example above. For every restriction you can set name, comment, preliminary selection and field tests and also select on which pages this restriction will be active:

![Restriction page](screenshots/restriction.png)

Each restriction can be applied to all queues or only specified ones:

![Applies to page](screenshots/apply_to_queues.png)

If restriction has failed then user sees fields that caused fail, restriction name and comment (if any):

![Failed restriction on ticket modify page](screenshots/restriction_failed.png)

# Dependencies:

* RT >= 4.0.0
* experimental

# Installation

Execute this command:

$ perl Makefile.PL && make && make install

# Configuration

To use the extension write in RT_SiteConfig.pm following:

For RT>=4.2:

```
Plugin( "RT::Extension::FieldsControl" );
```

For RT<4.2:

```
Set(@Plugins, qw(RT::Extension::FieldsControl));
```

After installing you may need to clear Mason cache and restart webserver.

# Work summary

To configure restrictions go to *Admin->Tools->Fields Control* (you must have SuperUser rights).

Each restriction consists of:
* "Common" section -- restriction name, Enable checkbox;
* "Applies to" section -- which tickets this restriction is applied to. Restriction will be applied if ticket satisfied to TicketSQL expression and if all (AND) or some (OR) new state tests will be passed (if any);
* "Fails if" section -- error will be raised if all (AND) or some (OR) tests will be passed.

When user tries to update a ticket the following algorithm performs:
1. Select only restrictions applicable to the current ticket among all enabled restrictions ("Applies to" section);
2. New state will be tested against "Fails if" section tests of all selected restrictions;
3. If "Fails if" section gives true, then the restriction considered as failed;
4. If we have failed restrictions from previous step then show them all in the error message and abort ticket updating.

NOTE: if field was set with multiple values on the page then each of value will be tested.


# Author

Igor Derkach, <gosha753951@gmail.com>


# Bugs

Please report any bugs or feature requests to the author.


# Copyright and license

Copyright 2018 Igor Derkach, <https://github.com/bdragon300/>

This program is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

Request Tracker (RT) is Copyright Best Practical Solutions, LLC.
