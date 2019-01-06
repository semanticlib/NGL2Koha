#!/usr/bin/perl
#
# @File prepare_marc.pl
# @Author Saiful Amin <saiful@semanticconsulting.com>
# Description: Extract MARC records from NGL and prepare it for Koha ILS
#

use strict;
use warnings;
use POSIX;
use MARC::Record;
use MARC::File::XML;
use MARC::File::MARCMaker;
use YAML::XS 'LoadFile';
use DBI;
MARC::File::XML->default_record_format('USMARC');

my $config = LoadFile('config.yml');
my $delete_tags = $config->{delete_marc_tags};
my $delete_ind  = $config->{delete_indicators};
my $item_type   = $config->{item_type_map};
my $shelving    = $config->{shelving_stack};

my $dbh =
  DBI->connect( "dbi:Pg:dbname=$config->{dbname};host=$config->{dbhost}",
    $config->{dbuser}, $config->{dbpass}, { 'RaiseError' => 1 } );

# NGL Material Types table
my $material_type = {};
my $msth          = $dbh->prepare('SELECT * FROM adm_co_material_type');
$msth->execute();
while ( my $row = $msth->fetchrow_hashref() ) {
    $material_type->{ $row->{material_type_id} } = $row->{material_type};
}

# NGL Item Location table
my $ngl_location = {};
my $lsth         = $dbh->prepare('SELECT location_id, location FROM location');
$lsth->execute();
while ( my $row = $lsth->fetchrow_hashref() ) {
    $ngl_location->{ $row->{location_id} } = $row->{location};
}

# Extract MARC records from DB
#my $query = "SELECT cataloguerecordid, wholecataloguerecord, xml_wholerecord,
my $query = "SELECT cataloguerecordid, xml_wholerecord, language
    FROM searchable_cataloguerecord";

my $sth = $dbh->prepare($query);
$sth->execute();

# Prepare Item rows extraction queries to be used for each bib record
my $item_query = "SELECT d.accession_number, d.call_number, d.location_id,
        d.classification_number, d.book_number, d.material_type_id,
        TO_CHAR( d.entry_date, 'YYYY-MM-DD') as \"acc_date\"
    FROM document d
    LEFT JOIN cat_volume cv ON d.volume_id = cv.volume_id
    LEFT JOIN searchable_cataloguerecord sc ON cv.cataloguerecordid = sc.cataloguerecordid
    WHERE sc.cataloguerecordid = ?";

my $item_sth = $dbh->prepare($item_query);

# Set the date string
my $date = POSIX::strftime("%Y%m%d", localtime);
#$today = POSIX::strftime("%Y-%m-%d", localtime);

# Open the Output filehandle in UTF-8 mode
my $outfile = $ARGV[0] || 'out.mrc';
open( OUT, ">$outfile" );
binmode OUT, ":encoding(UTF-8)";

$| = 1;    # autoflush for showing progress dots

my $rec_num = 0;
while ( my $row = $sth->fetchrow_hashref() ) {
    $rec_num++;
    last if ( $ENV{LIMIT} && $rec_num > $ENV{LIMIT} );

    my $rec_id = $row->{'cataloguerecordid'};

    #    my $iso2709 = $row->{'wholecataloguerecord'};
    my $marcxml = $row->{'xml_wholerecord'};
    my $lang    = $row->{'language'};

    #    my $record = MARC::Record->new_from_usmarc($iso2709);
    my $record = MARC::Record->new_from_xml( $marcxml, 'UTF-8' );

    # fix language of record
    $lang = get_langcode( $record->title() )
      unless ( $lang && $lang =~ /[a-z]{3}/ );

    # create record ID field, if missing
    my $tag_001 = $record->field('001');
    if ($tag_001) {
        $tag_001->replace_with( MARC::Field->new( '001', 'NGL' . $rec_id ) );
    }
    else {
        $tag_001 = MARC::Field->new( '001', 'NGL' . $rec_id );
        insert_tag( $record, $tag_001, 1 );
    }

    # Fix date in 260$c
    my $pubdt   = '';
    my $tag_260 = $record->field('260');
    if ( $tag_260 && $tag_260->subfield('c') ) {
        $pubdt = $tag_260->subfield('c');
        $pubdt =~ s/[^[:ascii:]]//g; # remove non-ascii stuff from date
        $tag_260->update( 'c' => clean_spaces($pubdt) );
        update_imprint($tag_260);
    }

    # Create and append/replace tag_008 (for Books)
    my $tag_008 = $record->field('008');
    my $data_008 = substr( $date, -6 ) . "|                r|    ||1|||eng||||";
    substr( $data_008, 0, 6 ) = substr( $tag_008->as_string(), 0, 6 )
      if $tag_008;
    substr( $data_008, 6,  1 ) = 's';
    substr( $data_008, 7,  4 ) = $pubdt if $pubdt =~ /\d{4}/;
    substr( $data_008, 35, 3 ) = $lang;

    my $new_008 = MARC::Field->new( '008', $data_008 );
    if ($tag_008) {
        $tag_008->replace_with($new_008);
    }
    else {
        insert_tag( $record, $new_008, 8 );
    }

    # delete tags
    foreach ( @{$delete_tags} ) {
        delete_tag( $record, $_ );
    }

    # language field
    my $tag_041 = MARC::Field->new( '041', '', '', 'a' => $lang );
    insert_tag( $record, $tag_041, 41 );

    # Delete duplicate Call number (082) field
    remove_duplicates( $record, '082' ) if $record->field('082');

    # Flags for missing Call or book number in 082
    my $tag_082          = $record->field('082');
    my $tag_082_missing  = $tag_082 ? 0 : 1;
    my $tag_082b_missing = ( $tag_082 && $tag_082->subfield('b') ) ? 0 : 1;

    my $tag_100 = $record->field('100');
    update_author($tag_100) if $tag_100;

    if ( !defined $record->field('245') ) {
        warn "\nRecord ID: $rec_id \tNo title (skipping)\n";
        next;
    }

    # Fix repeated tag 245
    my @tag_245 = $record->field('245');
    if ( $tag_245[1] ) {
        my ( $main_245, $second_245 ) = @tag_245;
        my @subfields = $second_245->subfields();
        while ( my $subfield = pop(@subfields) ) {
            my ( $code, $data ) = @$subfield;
            $main_245->update( $code => $data );
        }
        $record->delete_field($second_245);
    }
    reorder_subfields( $record->field('245') );
    my $title_ind1 = $tag_100 ? '1' : '0';
    update_title( $record->field('245'), $title_ind1 );

    reorder_subfields( $record->field('260') ) if $record->field('260');

    # fix indicators in subject
    my @tag_650 = $record->field('650');
    foreach (@tag_650) {
        fix_indicators( $_, '', '4' );
    }
    remove_duplicates( $record, '650' ) if $record->field('650');

    # fix punctuation for other authors
    my @tag_700 = $record->field('700');
    foreach (@tag_700) {
        update_author($_);
    }
    remove_duplicates( $record, '700' ) if $record->field('700');

    $item_sth->execute($rec_id);
  ITEM: while ( my $item_row = $item_sth->fetchrow_hashref() ) {
        my $barcode =
          $item_row->{'accession_number'}
          ? clean_spaces( $item_row->{'accession_number'} )
          : '';
        my $call_num  = $item_row->{'call_number'};
        my $loc_id    = $item_row->{'location_id'} || '';
        my $class_num = $item_row->{'classification_number'};
        my $book_num  = $item_row->{'book_number'};
        my $acc_date  = $item_row->{'acc_date'};
        my $cost      = $item_row->{'mrp_value'};
        my $status    = $item_row->{'status'} || '';
        my $mt_id     = $item_row->{'material_type_id'};

        # Update missing call number in bib from item details
        if ($class_num) {
            my $new_082 = MARC::Field->new( '082', '', '', 'a' => $class_num );
            $new_082->update( 'b' => clean_spaces($book_num) ) if $book_num;
            if ($tag_082_missing) {
                insert_tag( $record, $new_082, 82 );
                $tag_082_missing = 0;    # reset
            }
            if ($tag_082b_missing) {
                $tag_082->replace_with($new_082) if $tag_082;
                $tag_082b_missing = 0;    # reset
            }
        }

        # ignore blank barcodes
        if ( !$barcode ) {
            warn "\nNo barcode in Rec ID: $rec_id (skipping)\n";
            next ITEM;
        }

        my $tag_952 = MARC::Field->new(
            '952', '', '',
            '2' => $config->{classification},     # Classification source
            '8' => 'GEN',                         # Collection code (CCODE)
            'a' => $config->{library_branch},     # Home Branch
            'b' => $config->{library_branch},     # Holding Branch
            'c' => $config->{default_stack},      # Shelving stack
            'd' => $acc_date,
            'o' => $call_num,
            'p' => $barcode,
            'y' => $config->{default_item_type}
        );
        $tag_952->update( '8' => 'HIN' )                if $lang eq 'hin';
        $tag_952->update( '8' => 'URD' )                if $lang eq 'urd';
        $tag_952->update( 'c' => $shelving->{$loc_id} ) if $shelving->{$loc_id};
        $tag_952->update( 'g' => $cost )                if $cost;
        $tag_952->update( 'y' => $item_type->{$mt_id} ) if $item_type->{$mt_id};

        reorder_subfields($tag_952);
        $record->append_fields($tag_952);
    }

    # delete both indicators in tags
    foreach ( @{$delete_ind} ) {
        fix_indicators( $record->field($_) ) if $record->field($_);
    }

    print OUT $record->as_usmarc();

    print STDOUT MARC::File::MARCMaker->encode($record), "\n\n" if $ENV{DEBUG};
    print STDOUT "."                    if ( $rec_num % 200 == 0 );
    print STDOUT "\n$rec_num records\n" if ( $rec_num % 5000 == 0 );
}

# disconnect from db
$sth->finish();
my $duration = time - $^T;
warn "\n  $rec_num MARC record(s) created in $duration second(s)\n\n\n";

warn "  Import these records into Koha using the script:
   /usr/share/koha/bin/migration_tools/bulkmarcimport.pl\n\n";

## Helper sub-routines
###############################################
sub get_langcode {
    my $title = shift;
    return 'hin' if ( $title =~ /\p{Devanagari}/ );
    return 'urd' if ( $title =~ /\p{Arabic}/ );
    return 'eng';
}

sub update_author {
    my $tag = shift;
    $tag->update( ind1 => '0' );
    $tag->update( ind1 => '1' ) if $tag->as_string() =~ /,/;
    $tag->update( ind2 => ' ' );
    append_char( $tag, 'a', '.' ) if $tag->subfield('a');
    reorder_subfields($tag);
}

## Add AACR-2 type punctuation in title field
sub update_title {
    my ( $tag, $ind1 ) = @_;

    my $ind2 = title_ind2($tag) ? title_ind2($tag) : '0';
    $tag->update( ind1 => $ind1, ind2 => $ind2 );

    if ( $tag->subfield('b') ) {
        append_char( $tag, 'a', ' :' );
        append_char( $tag, 'b', ' /' );
    }
    else {
        append_char( $tag, 'a', ' /' ) if $tag->subfield('c');
    }

    append_char( $tag, 'c', '.' ) if $tag->subfield('c');
}

# Get title indicator
sub title_ind2 {
    my $tag = shift;

    return unless $tag->as_string() =~ /^[a-z]/i;
    my @w = split / /, $tag->as_string();
    if ( $w[0] =~ /^(a|an|the)/i ) {
        return length( $w[0] ) + 1;
    }
    return;
}

## Add AACR-2 type punctuation in imprint
sub update_imprint {
    my $tag = shift;
    append_char( $tag, 'a', ' :' ) if $tag->subfield('a');
    append_char( $tag, 'b', ', ' ) if $tag->subfield('b');
    append_char( $tag, 'c', '.' )  if $tag->subfield('c');
}

sub insert_tag {
    my ( $record, $field, $tag_pos ) = @_;
    my $before;
    foreach ( $record->fields() ) {
        $before = $_;
        last
          if $_->tag() > $tag_pos;
    }
    $record->insert_fields_before( $before, $field );
}

sub delete_tag {
    my ( $record, $tag_no ) = @_;
    my @marc_tags = $record->field($tag_no);
    foreach (@marc_tags) {
        $record->delete_field($_);
    }
}

# remove repeatable tags with duplicate values
sub remove_duplicates {
    my ( $record, $tag_no ) = @_;
    my @marc_tags = $record->field($tag_no);
    my $index     = {};

    foreach (@marc_tags) {
        my $data = clean_spaces( $_->as_string() );
        $index->{$data} += 1;
        if ( $index->{$data} > 1 ) {
            $record->delete_field($_);
        }
    }
}

# reorder subfields with ASCII sort, ignore $e in 100, 700
sub reorder_subfields {
    my $field = shift;

    my $field_data = {};
    for my $subfield ( $field->subfields() ) {
        my ( $code, $data ) = @{$subfield};
        next
          if ( $field->{_tag} =~ /100|700/
            && $code eq 'e'
            && $data =~ /author/i );
        $field_data->{$code} = $data;
    }
    return unless keys %{$field_data};
    my @subfields = ();
    foreach my $code ( sort keys %{$field_data} ) {
        push( @subfields, $code, $field_data->{$code} );
    }

    # create a new tag.
    my $new_field = MARC::Field->new(
        $field->{_tag},
        $field->indicator(1),
        $field->indicator(2), @subfields
    );

    # replace the existing subfield.
    $field->replace_with($new_field);
}

sub fix_indicators {
    my ( $field, $ind1, $ind2 ) = @_;
    $ind1 ||= ' ';
    $ind2 ||= ' ';
    $field->update( ind1 => $ind1, ind2 => $ind2 );
}

# Helper for AACR-2 type punctuation fix
sub append_char {
    my ( $tag, $code, $pun ) = @_;
    $pun ||= '.';
    if ( $tag->subfield($code) ) {
        my $data = clean_spaces( $tag->subfield($code) );
        $data .= $pun unless substr( $data, -1 ) eq $pun;
        $tag->update( $code => $data );
    }
}

sub clean_spaces {
    my $str = shift;
    $str =~ s/\s+,/, /g;
    $str =~ s/^\s+//;
    $str =~ s/\s+$//;
    $str =~ s/\s+/ /g;
    return $str;
}
