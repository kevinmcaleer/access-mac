# Fixture generator

`GenerateFixtures.java` builds the databases in `Tests/AccessEngineTests/Fixtures` with
[Jackcess](https://jackcess.sourceforge.io/), an independent Java implementation of the
Access file format, and writes a `.json` file beside each one with exactly what Jackcess
reads back. The engine tests compare our reader against those files.

To regenerate (needs Java 11+):

```sh
mkdir -p jars && cd jars
curl -fO https://repo1.maven.org/maven2/com/healthmarketscience/jackcess/jackcess/4.0.5/jackcess-4.0.5.jar
curl -fO https://repo1.maven.org/maven2/org/apache/commons/commons-lang3/3.14.0/commons-lang3-3.14.0.jar
curl -fO https://repo1.maven.org/maven2/commons-logging/commons-logging/1.3.0/commons-logging-1.3.0.jar
cd ..
java -cp "jars/*" Tools/FixtureGen/GenerateFixtures.java Tests/AccessEngineTests/Fixtures
```

Jackcess cannot create Access 97 (Jet 3) files, so Jet 3 fixtures will have to come from
real Access 97 databases.

## Checking edited files

`VerifyEdits.java` opens databases the Swift engine has edited and checks them with
Jackcess: every table's rows and row count, and every index's internal structure and entry
count. It then adds a row with Jackcess, to show the file's page maps are still usable. CI
runs it on the files the write tests save:

```sh
mkdir -p /tmp/edits
ACCESS_EDIT_OUTPUT=/tmp/edits swift test --filter WriteTests
java -cp "jars/*" Tools/FixtureGen/VerifyEdits.java /tmp/edits/edited-*
```
