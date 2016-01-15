# Summary

RT::Extension::RejectUpdate rejects page update while updating ticket based on fields value

# Description

Just after user click on Update Ticket button (or Save Changes) the extension validate ticket and transaction fields value according on preconfigured rules.
If some rules are match then user will stay on the same page and error message will point which matching fields list. If no rules was match then ticket update will not be interrupted.

Web interface only available for users with SuperUser right.

# Installation

Dependencies:

* RT >= 4.0.0

Commands to install:

  perl Makefile.PL
  make
  make install

# Configuration

To use the extension write in RT_SiteConfig.pm following:

For RT>=4.2:

```
Plugin( "RT::Extension::RejectUpdate" );
```

For RT<4.2:

```
Set(@Plugins, qw(RT::Extension::RejectUpdate));
```

After installing you may need to clean Mason cache and restart RT process.

Web interface will be available for users with SuperUser right in Admin->Tools->Crontab.

# Work summary

This extension configures via web-interface. Configuration will be written to the database as one RT::Attribute entry.

Configuration consists of number of rules. Each rule checks separately on matching to actual and "new" values. Accordingly ticket actual values is "Old ticket state" and fields that will be after update is "New ticket state".
Each rule will be checked by following algorithm:

* If ticket matches "old ticket state" and its fields that would be after update matches to "new ticket state" that goto step 2
* If "checking fields" are matching to "new ticket state" then reject update and show error

"New ticket state" and "Checking fields" has AND/OR switch that has following meaning:
* AND - when ALL fields match
* OR - when ANY field match

# Special fields

## Transaction.Type

Identifies on what page user is. Can have following values:

* Comment, Update, Status - Comment;
* Correspond, Update, Reply, Status - Correspond;
* Set, Basics, Modify, CustomField, Status - Basics page;
* Jumbo, ModifyAll, Status - Jumbo update.

Several pages can have the same Transaction.Type.