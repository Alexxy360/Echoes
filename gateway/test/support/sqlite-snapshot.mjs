/** Test-only consistent snapshots of owned synthetic SQLite tables. Not a Cloudflare PITR test. */
export function sqliteSnapshot(db, predicate = () => true) {
  return db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").all()
    .map(row => row.name).filter(predicate).map(name => {
      if (!/^[a-z0-9_]+$/.test(name)) throw new Error("Unsafe test table name.");
      return { name, rows: db.prepare(`SELECT * FROM ${name}`).all().map(row => ({ ...row })) };
    });
}
export function restoreSQLite(storage, snapshot) {
  storage.transactionSync(() => {
    for (const { name, rows } of snapshot) {
      if (!/^[a-z0-9_]+$/.test(name)) throw new Error("Unsafe test table name.");
      storage.sql.exec(`DELETE FROM ${name}`);
      for (const row of rows) {
        const keys = Object.keys(row);
        if (keys.some(key => !/^[a-z0-9_]+$/.test(key))) throw new Error("Unsafe test column name.");
        storage.sql.exec(`INSERT INTO ${name}(${keys.join(",")}) VALUES(${keys.map(() => "?").join(",")})`, ...keys.map(key => row[key]));
      }
    }
  });
}
