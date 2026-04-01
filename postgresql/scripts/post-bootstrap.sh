#!/bin/bash
set -e

# Called by Patroni after bootstrap (first-time cluster init only).
# Creates the adempiere application database and user.

psql -U postgres <<SQL
CREATE ROLE adempiere WITH LOGIN PASSWORD '${ADEMPIERE_PASSWORD}' CREATEDB;
CREATE DATABASE adempiere OWNER adempiere;
SQL
