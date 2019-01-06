#!/usr/bin/perl
#
# Name: patron_migrate.pl
# Author: Saiful Amin <saiful@semanticconsulting.com>
# Description: Patron data migration from NewGenLib db into Koha ILS

use strict;
use warnings;
use DBI;
use String::Random;
use Koha::AuthUtils qw/hash_password/;
use Crypt::Eksblowfish::Bcrypt qw(bcrypt en_base64);
use Encode qw( encode is_utf8 );
use YAML::XS 'LoadFile';

my $config = LoadFile('config.yml');
my $params = $config->{parameters} || '';
my $random = new String::Random;

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
my $query = "SELECT patron_id as cardnumber, dept_id, course_id,
        CONCAT_WS(' ', fname, mname, lname) as surname,
        address1, address2, state, country, pin, phone2,
        COALESCE(BTRIM(city), 'No City') as city, email, phone1 as phone,
        paddress1, paddress2, pcity, pstate, pcountry, ppin,
        COALESCE(pphone1, pphone2) as pphone, pemail, status,
        TO_CHAR(membership_start_date, 'yyyy-mm-dd') as dateenrolled,
        TO_CHAR(membership_expiry_date, 'yyyy-mm-dd') as dateexpiry,
        patron_category_id as categorycode
    FROM patron";

my $nglib_sth = $nglib_dbh->prepare($query);
$nglib_sth->execute();

my $branch              = $config->{library_branch};
my $patron_type         = $config->{patron_type_map};
my $default_patron_type = $config->{default_patron_type};

my $unblock = {};

# Currently checked out
my $insert_patron = "INSERT INTO borrowers (cardnumber, surname, address,
    address2, city, state, country, zipcode, email, mobile, dateenrolled,
    dateexpiry, branchcode, categorycode, phone, B_address, B_address2, B_city,
    B_state, B_country, B_zipcode, B_phone, B_email, userid, password,
    debarred, debarredcomment)
    VALUES (?,?,?,?, ?,?,?,?, ?,?,?,?, ?,?,?,?, ?,?,?,?, ?,?,?,?, ?,?,?)";

my $insert_attr = "INSERT INTO borrower_attributes (borrowernumber, code,
    attribute) VALUES (
    (SELECT borrowernumber FROM borrowers where cardnumber = ?), ?, ?)";

my $block_patron = "INSERT INTO borrower_debarments (borrowernumber, type,
    comment) VALUES (
    (SELECT borrowernumber FROM borrowers where cardnumber = ?),
	'SUSPENSION', 'Blocked in NGL')";

my $rec_num = 0;
while ( my $row = $nglib_sth->fetchrow_hashref() ) {
    my $password = hash_password( $random->randpattern("CCccnn!") );
    my $debarred = my $comments = 'NULL';
    if ( $row->{'status'} eq 'B' ) {
        ( $debarred, $comments ) = ( '9999-12-31', 'Blocked in NGL' )
          unless $unblock->{ $row->{'cardnumber'} };
    }

    # Set Patron type
    my $category_code =
      ( $row->{'categorycode'} && $patron_type->{ $row->{'categorycode'} } )
      ? $patron_type->{ $row->{'categorycode'} }
      : $default_patron_type;

    my $koha_sth = $koha_dbh->prepare($insert_patron);
    $koha_sth->execute(
        $row->{'cardnumber'}, $row->{'surname'},      $row->{'address1'},
        $row->{'address2'},   $row->{'city'},         $row->{'state'},
        $row->{'country'},    $row->{'pin'},          $row->{'email'},
        $row->{'phone'},      $row->{'dateenrolled'}, $row->{'dateexpiry'},
        $branch,              $category_code,         $row->{'phone2'},
        $row->{'paddress1'},  $row->{'paddress2'},    $row->{'pcity'},
        $row->{'pstate'},     $row->{'pcountry'},     $row->{'ppin'},
        $row->{'pphone1'},    $row->{'pemail'},       $row->{'cardnumber'},
        $password,            $debarred,              $comments
    );

    # Insert patron attributes
    if ($params) {
        my $koha_sth2 = $koha_dbh->prepare($insert_attr);
        foreach my $param ( keys %{$params} ) {
            my $value = $row->{ $params->{$param}->{'id_field'} };
            $koha_sth2->execute( $row->{'cardnumber'}, $param, $value )
              if $value;
        }
    }

    # Insert debarment info
    if ($debarred) {
        my $koha_sth3 = $koha_dbh->prepare($block_patron);
        $koha_sth3->execute( $row->{'cardnumber'} );
    }

    $rec_num++;
    print STDOUT "$rec_num records\n" if ( $rec_num % 200 == 0 );
}

my $duration = time - $^T;
warn "All Patron records ($rec_num) migrated in $duration second(s)\n";
