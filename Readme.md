# NGL2Koha

**Data migration scripts for moving from [NewGenLib](http://www.verussolutions.biz/web) to [Koha ILS](https://koha-community.org)**

These are a set of Perl scripts to migrate:
1. Bibliographic and item holdings data.
2. Patrons Data with any additional attributes.
3. Circulation transactions, including circulation history.

These scripts are slightly dumbed-down version from a real data migration project.

***
:warning: **Warning !!!**

These are command-line scripts, not plug-n-play stuff. Some familiarity with Linux (like Ubuntu) is mandatory. We assume no responsibility if you break something!

**Assumptions & Disclaimers**

- The steps mentioned below assumes you are running some version of Ubuntu LTS. Commands can be altered based on the platform.
- The scripts provided here are as generic as could be prepared. Implementation specific data cleaning and fields mapping are removed for the sake of simplicity.
- The scripts have been tested on NGL 3 and Koha 18.11

## Installation / Setup

#### Clone this repository
```
git clone https://github.com/semanticlib/NGL2Koha.git
```

#### Install dependencies
Installation of Koha will take care of most the Perl dependencies.

Other Perl module dependencies are:
* DBD::Pg
* YAML::LibYAML
* MARC::File::MARCMaker

These may be installed either from [CPAN](https://metacpan.org) or from OS repositories.

**On Ubuntu/Debian, following should work:**

```
sudo apt-get install libdbd-pg-perl libmarc-file-marcmaker-perl libyaml-libyaml-perl
```

#### Configuration

Edit the `config.yml` with appropriate details.

## Preparation

The migrations steps mentioned below must be be tested on a test/staging instance of both Koha and NGL, before attempting this on production.

#### Prepare NGL Staging
The scripts provided here does not do any changes in the NGL database. Even then it is advisable to run these against a staging instance of NGL database copy. Mostly for security reasons. Final migration can be done using the production database.

Configure the NGL database credentials in the `config.yml`.

#### Prepare Koha Staging
* Create a new instance of Koha, say 'demo' for testing the data migration.
* Configure all the required parameters:
    - Create the branches.
    - Create the item types. Add those item types mapping in `config.yml`.
    - Create patron categories. Configure these mappings in `config.yml`.
    - Create authorized values to store extra Patron attributes, if any.
    - Configure Patron attributes to use the authorized values.
    - Configure default circulation policy, if not all.
    - Create a simple bibliographic framework with less restrictions than 'Default'.
* Take backup of the database after the configuration. This can be restored after each iteration of data import testing or if something goes wrong.


## Migrate Bibliographic Data

#### Prepare MARC data

```
perl prepare_marc.pl data.mrc
```

Test the data with any MARC viewer, such [`yaz-marcdump`](https://software.indexdata.com/yaz/doc/yaz-marcdump.html) or [MARCEdit](https://marcedit.reeset.net/). 

Alternatively, enable DEBUG mode to view format MARC records with these commands:

```bash
export DEBUG=1
perl prepare_marc.pl data.mrc
```

You can also limit the number of records being created using LIMIT variable:

```bash
export LIMIT=10
perl prepare_marc.pl data.mrc
```


#### Import MARC data

For small datasets, it is often easier to import MARC using the Koha Tools menu. For larger datasets, the command-line tool is recommended.

It might be good idea to stop Koha indexer before importing a big dataset.

```bash
sudo koha-indexer --stop demo
```

This migration must be done as the koha-instance-user since it requires instance specific configuration. For example, if the instance name is 'demo' the commands are:

```bash
sudo koha-shell demo
perl /usr/share/koha/bin/migration_tools/bulkmarcimport.pl -fk -framework FA -commit 1000 -file data.mrc
exit
```

Follow the [Koha Wiki](https://wiki.koha-community.org/wiki/Main_Page) for detailed documentation on the MARC import options.

#### Re-build Koha Index
	
```
sudo koha-rebuild-zebra -f -b -v demo
```

Re-start the Koha indexer now if required:

```
sudo koha-indexer --start demo
```

## Migrate Patrons Data

Update the `config.yml` with correct database mapping before running the scripts.

#### Migrate the NGL parameters into Koha authorized values (Optional)

Read the instructions in `config.yml` before running this script:

```
perl params_migrate.pl
```

Use this only if you need to migrate additional patron attributes.

**Note:** If you are not using this, comment out the parameters sections in `config.yml`.

#### Migrate the patron records

This migration must be done as the koha-instance-user since it uses some Koha specific modules. For example, if the instance name is 'demo' the commands are:

```bash
sudo koha-shell demo
perl patron_migrate.pl
exit
```

**Note:** This generates random password for each patron. If password field is available in NGL database in plain text, it can encrypted before importing into Koha. Please create an issue if you need help with that.

## Migrate Circulation Transactions

```
perl circ_migrate.pl
```

If something doesn't work, please report them in the issues.
