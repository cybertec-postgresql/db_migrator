# Contributing

## Pull Requests

Except for small changes, PRs should always address an already open and accepted
issue. Otherwise you run the risk of spending time implementing something and
then the PR being rejected because the feature you implemented was not actually
something we want in db_migrator.

It's a good idea to first comment under the issue to ask
whether it is something that can/should be worked on right now. This is
especially true for issues labeled with `enhancement`, where a feature may depend
on some other things being implemented first or it may need to be split into
many smaller features, because it is too big otherwise.

In particular, this means that you should not open a feature request and
immediately start working on that feature, unless you are very sure it will be
accepted or accept the risk of it being rejected.

Things like documentation changes or refactorings don't necessarily need an
issue associated with them. These changes are less likely to be rejected, since
they don't change the behavior of db_migrator. Nevertheless, for bigger changes
or when in doubt, open an issue and ask whether such changes would be desirable.

To claim an issue, comment under it to let others know that you are working on
it.

Feel free to ask for feedback about your changes at any time. Especially when
implementing features, this can be very useful because it allows us to make sure
you are going in the direction we had envisioned for that feature and you don't
lose time on something that ultimately has to be rewritten. In that case, a
[draft PR] is a useful tool.

[draft PR]: https://github.blog/2019-02-14-introducing-draft-pull-requests

## Testing

Your PR must pass all existing tests. If possible, you should also add tests for
the things you write. `db_migrator` uses the [pgTAP] testing framework and the
[PGXS] build infrastructure. Unit tests live in the `test/sql/` directory; they
can be used with `make installcheck`.

All you need are:

* PostgreSQL binary with PGXS build infrastructure (`devel` package)
* a running PostgreSQL instance with valid credentials
* the pgTAP framework

[pgTAP]: https://pgtap.org/documentation.html
[PGXS]: https://www.postgresql.org/docs/current/extend-pgxs.html

```sh
make install
make installcheck
```

To run a specific test file, use the `REGRESS` variable:

```sh
make REGRESS=tables install installcheck
```

### Adding new tests and dataset

All new testing files need to be added to the `test/schedules/tests.txt` file
and must respect the correct ordering. If tests cover a new feature, the
dataset must first be inserted into the database by using the `setup` scripts
to reflect the plugin's remote catalog (a.k.a. metaviews).

All new user tables must be attached to a datafile located in the `test/data/`
directory with a name composed of the `schema` and `table` names. For example,
`Schema1.Table1.dat` will be attached to the table `Schema1.Table1` (names are
case sensitive).
