# Directo-TCPlus-bridge

Small utility for transferring data between Directo ERP and Kasten TCPlus WMS software

The following data is transferred:

* Items
* Picking orders
* Shelving requests (purchase orders)

## Setup

* Install ruby (See .ruby-version file for the tested version)
* Git clone or download the files
* Copy config-example.yml to config.yml
* Update settings as necessary
* Run ```gem install bundler```
* Run ```bundle install```
* Run program with ```ruby app.rb```
