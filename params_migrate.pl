#!/usr/bin/perl
#
# Name: params_migrate.pl
# Author: Saiful Amin <saiful@semanticconsulting.com>
# Description: Migrate parameters from NewGenLib db into Koha ILS

use strict;
use warnings;
use DBI;
use YAML::XS 'LoadFile';

my $config = LoadFile('config.yml');
my $params = $config->{parameters};

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

# authorized values insert
my $insert_values = "INSERT INTO authorised_values (category, authorised_value, 
    lib, lib_opac) VALUES (?, ?, ?, ?)";

foreach my $param ( keys %{$params} ) {

    # Get all id,value from NewGenLib db
    my $p     = $params->{$param};
    my $query = "SELECT $p->{'id_field'} AS id, $p->{'value_field'} AS value 
        FROM $p->{'table_name'}";
    my $nglib_sth = $nglib_dbh->prepare($query);
    $nglib_sth->execute();

    my $rec_num = 0;
    print STDOUT "adding: $param ...\n";
    while ( my $r = $nglib_sth->fetchrow_hashref() ) {
        my $koha_sth = $koha_dbh->prepare($insert_values);
        $koha_sth->execute( $param, $r->{'id'}, $r->{'value'}, $r->{'value'} );
        $rec_num++;
        print STDOUT "\t$r->{'id'} -> $r->{'value'}\n";
    }

    warn "All $param parameters ($rec_num) migrated\n\n";
}
