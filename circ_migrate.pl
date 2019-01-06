#!/usr/bin/perl
#
# Name: circ_migrate.pl
# Author: Saiful Amin <saiful@semanticconsulting.com>
# Description: Circulation data migration from NewGenLib db into Koha ILS

use strict;
use warnings;
use DBI;
use YAML::XS 'LoadFile';

my $config = LoadFile('config.yml');

# Koha db connection
my $koha_dbh = DBI->connect(
    "DBI:mysql:database=$config->{kohadb_name};host=$config->{kohadb_host}",
    $config->{kohadb_user},
    $config->{kohadb_pass},
    { 'RaiseError' => 1 }
);

# NewGenLib db
my $nglib_dbh =
  DBI->connect( "dbi:Pg:dbname=$config->{dbname};host=$config->{dbhost}",
    $config->{dbuser}, $config->{dbpass}, { 'RaiseError' => 1 } );

# Get all circulation from NewGenLib db
my $query = "SELECT patron_id as cardnumber, accession_number as barcode,
        TO_CHAR(ta_date, 'yyyy-mm-dd') as issuedate,
        TO_CHAR(due_date, 'yyyy-mm-dd hh24:mi:ss') as date_due,
        TO_CHAR(checkin_date, 'yyyy-mm-dd hh24:mi:ss') as returndate
    FROM cir_transaction
	ORDER BY ta_date ASC";
$query .= " LIMIT $ENV{LIMIT}" if $ENV{LIMIT};

my $nglib_sth = $nglib_dbh->prepare($query);
$nglib_sth->execute();

my $branch = $config->{library_branch};

# Currently checked out
my $insert_issue = "INSERT INTO issues
    (borrowernumber, itemnumber, issuedate, date_due, returndate, branchcode)
    VALUES (
        (SELECT borrowernumber FROM borrowers where cardnumber = ?),
        (SELECT itemnumber FROM items where barcode = ?),
        ?, ?, ? , \'$branch\'
)";
$koha_dbh->do(qq|ALTER TABLE issues DROP INDEX itemnumber|);
warn "\nThe UNIQUE key constraint 'itemnumber' dropped from 'issues' table
	(this constraint will be re-instated after the migration)\n\n";

$| = 1;    # autoflush
my $rec_num = 0;
while ( my $row = $nglib_sth->fetchrow_hashref() ) {
    my $koha_sth = $koha_dbh->prepare($insert_issue);
    $koha_sth->execute(
        $row->{'cardnumber'}, $row->{'barcode'}, $row->{'issuedate'},
        $row->{'date_due'},   $row->{'returndate'}
    );

    $rec_num++;
    print STDOUT "."                    if ( $rec_num % 100 == 0 );
    print STDOUT "\n$rec_num records\n" if ( $rec_num % 2000 == 0 );
}

warn "\nAll circulation records ($rec_num) imported into 'issues' table.\n\n";

my $copy_issues = "INSERT INTO old_issues 
		SELECT * FROM issues WHERE returndate IS NOT NULL";
$koha_dbh->do($copy_issues);

my $delete_issues = "DELETE FROM issues WHERE returndate IS NOT NULL";
$koha_dbh->do($delete_issues);

warn ".........\n\nMoved old circulation records into 'old_issues' table\n\n";

# Update items.onloan using values from issues.date_due
my $item_loan = "UPDATE items SET onloan = ? WHERE itemnumber = ?";
my $item_update = $koha_dbh->prepare($item_loan);

my $current_issues = "SELECT itemnumber, date_due FROM issues";
my $issued_items = $koha_dbh->prepare( $current_issues );
$issued_items->execute();

while(my @row = $issued_items->fetchrow_array()) {
    $item_update->execute( $row[1], $row[0] );
}

warn ".........\n\nUpdated item loan status with due date for all issued items\n\n";

# Re-instate the UNIQUE constraint
$koha_dbh->do(
    qq|ALTER TABLE issues ADD CONSTRAINT itemnumber UNIQUE (itemnumber)|);
warn "The constraint 'itemnumber' re-instated in the 'issues' table.\n\n";

my $duration = time - $^T;
warn "Circulation data migration completed in $duration second(s)\n\n";

warn "Before running the circulation reports, run the following script:
    /usr/share/koha/bin/recreateIssueStatistics.pl\n\n";
