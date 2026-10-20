// Generates the .mdb/.accdb engine test fixtures with Jackcess, plus a JSON
// file per database describing exactly what Jackcess reads back from it.
//
// Usage (see Tools/FixtureGen/README.md):
//   java -cp "jars/*" GenerateFixtures.java <output-dir>

import com.healthmarketscience.jackcess.*;
import com.healthmarketscience.jackcess.Database.FileFormat;
import java.io.*;
import java.math.BigDecimal;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.time.LocalDateTime;
import java.util.*;

public class GenerateFixtures {
  public static void main(String[] args) throws Exception {
    Path out = Paths.get(args.length > 0 ? args[0] : "Tests/AccessEngineTests/Fixtures");
    Files.createDirectories(out);
    generate(out, "jet4-2000.mdb", FileFormat.V2000);
    generate(out, "jet4-2003.mdb", FileFormat.V2003);
    generate(out, "ace12-2007.accdb", FileFormat.V2007);
    generate(out, "ace14-2010.accdb", FileFormat.V2010);
    generate(out, "ace16-2016.accdb", FileFormat.V2016);
  }

  static String repeat(String s, int n) { return String.join("", Collections.nCopies(n, s)); }

  static void generate(Path dir, String name, FileFormat fmt) throws Exception {
    File f = dir.resolve(name).toFile();
    f.delete();
    try (Database db = new DatabaseBuilder(f).setFileFormat(fmt).create()) {
      db.setDateTimeType(DateTimeType.LOCAL_DATE_TIME);

      Table all = new TableBuilder("AllTypes")
          .addColumn(new ColumnBuilder("ID", DataType.LONG).setAutoNumber(true))
          .addColumn(new ColumnBuilder("TextField", DataType.TEXT).setLengthInUnits(100))
          .addColumn(new ColumnBuilder("MemoField", DataType.MEMO))
          .addColumn(new ColumnBuilder("ByteField", DataType.BYTE))
          .addColumn(new ColumnBuilder("IntField", DataType.INT))
          .addColumn(new ColumnBuilder("LongField", DataType.LONG))
          .addColumn(new ColumnBuilder("SingleField", DataType.FLOAT))
          .addColumn(new ColumnBuilder("DoubleField", DataType.DOUBLE))
          .addColumn(new ColumnBuilder("CurrencyField", DataType.MONEY))
          .addColumn(new ColumnBuilder("DateField", DataType.SHORT_DATE_TIME))
          .addColumn(new ColumnBuilder("BoolField", DataType.BOOLEAN))
          .addColumn(new ColumnBuilder("GuidField", DataType.GUID))
          .addColumn(new ColumnBuilder("NumericField", DataType.NUMERIC).setPrecision(18).setScale(4))
          .addColumn(new ColumnBuilder("BinaryField", DataType.BINARY).setLength(50))
          .addColumn(new ColumnBuilder("OleField", DataType.OLE))
          .addIndex(new IndexBuilder(IndexBuilder.PRIMARY_KEY_NAME).addColumns("ID").setPrimaryKey())
          .toTable(db);

      all.addRow(Column.AUTO_NUMBER, "Hello", "Short memo", (byte) 7, (short) -1234, 123456789, 1.5f, 3.141592653589793,
          new BigDecimal("1234.5678"), LocalDateTime.of(2024, 2, 29, 13, 45, 30), true,
          "{6F9619FF-8B86-D011-B42D-00C04FC964FF}", new BigDecimal("-98765.4321"),
          new byte[] {1, 2, 3, (byte) 0xFF}, new byte[] {9, 8, 7});
      all.addRow(Column.AUTO_NUMBER, "Ünïcödé ✓ 日本語", "Ωμέγα " + repeat("memo ", 400), (byte) 255, (short) 32767,
          -2147483648, -0.25f, -1.0e-10, new BigDecimal("-0.0001"), LocalDateTime.of(1899, 12, 30, 0, 0, 0), false,
          null, new BigDecimal("0"), new byte[0], null);
      all.addRow(Column.AUTO_NUMBER, null, null, null, null, null, null, null, null, null, false, null, null, null, null);
      StringBuilder huge = new StringBuilder();
      for (int i = 0; i < 3000; i++) huge.append("line ").append(i).append(" — ");
      byte[] blob = new byte[20000];
      for (int i = 0; i < blob.length; i++) blob[i] = (byte) (i * 31);
      all.addRow(Column.AUTO_NUMBER, "", huge.toString(), (byte) 0, (short) 0, 0, 0f, 0.0,
          new BigDecimal("922337203685477.5807"), LocalDateTime.of(1753, 1, 1, 6, 0, 0), true,
          "{00000000-0000-0000-0000-000000000001}", new BigDecimal("99999999999999.9999"),
          new byte[50], blob);
      all.addRow(Column.AUTO_NUMBER, "Line1\r\nLine2\t\"quoted\"", "€uro sign is not latin-1", (byte) 1, (short) 1, 1,
          123456.78f, 1e300, new BigDecimal("0.01"), LocalDateTime.of(9999, 12, 31, 23, 59, 59), false, null,
          new BigDecimal("0.0001"), null, null);

      Table many = new TableBuilder("ManyRows")
          .addColumn(new ColumnBuilder("ID", DataType.LONG).setAutoNumber(true))
          .addColumn(new ColumnBuilder("Name", DataType.TEXT).setLengthInUnits(50))
          .addColumn(new ColumnBuilder("Value", DataType.LONG))
          .addIndex(new IndexBuilder(IndexBuilder.PRIMARY_KEY_NAME).addColumns("ID").setPrimaryKey())
          .toTable(db);
      List<Object[]> rows = new ArrayList<>();
      for (int i = 1; i <= 1500; i++) rows.add(new Object[] {Column.AUTO_NUMBER, "Row number " + i, i * 3});
      many.addRows(rows);
      IndexCursor c = CursorBuilder.createCursor(many.getPrimaryKeyIndex());
      for (Row r : c) {
        if (((Integer) r.get("ID")) % 7 == 0) c.deleteCurrentRow();
      }

      Table evolving = new TableBuilder("Customers & Orders")
          .addColumn(new ColumnBuilder("Code", DataType.TEXT).setLengthInUnits(10))
          .addColumn(new ColumnBuilder("Amount", DataType.MONEY))
          .toTable(db);
      evolving.addRow("A1", new BigDecimal("10.5"));
      evolving.addRow("B2", new BigDecimal("-3"));
      new ColumnBuilder("Note", DataType.TEXT).setLengthInUnits(255).addToTable(evolving);
      new ColumnBuilder("Count", DataType.INT).addToTable(evolving);
      evolving.addRow("C3", new BigDecimal("0"), "added later", (short) 42);

      buildIndexed(db);

      if (fmt == FileFormat.V2016) {
        db.setAllowAutoNumberInsert(false);
        try {
          Table big = new TableBuilder("BigNumbers")
              .addColumn(new ColumnBuilder("Big", DataType.BIG_INT))
              .toTable(db);
          big.addRow(9007199254740993L);
          big.addRow(-42L);
        } catch (Exception e) {
          System.err.println("BIG_INT unsupported: " + e);
        }
      }
    }
    writeExpected(f, dir.resolve(name + ".json"));
    System.out.println("wrote " + f);
  }

  // Words that exercise the text index encoding: case, accents, ligatures,
  // punctuation (ignored or significant), control characters and CJK.
  static final String[] WORDS = {
    "apple", "Apple", "APPLE", "éclair", "Eclair", "naïve", "Straße", "strasse", "æsir", "Ærø",
    "co-op", "coop", "co op", "O'Brien", "o’brien", "tab\there", "bell\u0007x", "日本", "中文", "한국어",
    "Ωmega", "zebra", "Zürich", "1st", "10th", "2nd", "#hash", "$cash", "_under", "~tilde",
    "ñandú", "Œuvre", "ﬁne", "Ångström", "", " lead", "trail  ", "x\u00ADy", "€uro", "ÿes"
  };

  static void buildIndexed(Database db) throws Exception {
    Table t = new TableBuilder("Indexed")
        .addColumn(new ColumnBuilder("ID", DataType.LONG).setAutoNumber(true))
        .addColumn(new ColumnBuilder("Name", DataType.TEXT).setLengthInUnits(80))
        .addColumn(new ColumnBuilder("Amount", DataType.DOUBLE))
        .addColumn(new ColumnBuilder("Small", DataType.INT))
        .addColumn(new ColumnBuilder("Tiny", DataType.BYTE))
        .addColumn(new ColumnBuilder("Price", DataType.MONEY))
        .addColumn(new ColumnBuilder("Ratio", DataType.FLOAT))
        .addColumn(new ColumnBuilder("When", DataType.SHORT_DATE_TIME))
        .addColumn(new ColumnBuilder("Flag", DataType.BOOLEAN))
        .addColumn(new ColumnBuilder("Code", DataType.GUID))
        .addColumn(new ColumnBuilder("Dec", DataType.NUMERIC).setPrecision(12).setScale(3))
        .addColumn(new ColumnBuilder("Bin", DataType.BINARY).setLength(20))
        .addIndex(new IndexBuilder(IndexBuilder.PRIMARY_KEY_NAME).addColumns("ID").setPrimaryKey())
        .addIndex(new IndexBuilder("ByName").addColumns("Name"))
        .addIndex(new IndexBuilder("ByAmountDesc").addColumns(false, "Amount"))
        .addIndex(new IndexBuilder("BySmall").addColumns("Small"))
        .addIndex(new IndexBuilder("ByTiny").addColumns(false, "Tiny"))
        .addIndex(new IndexBuilder("ByPrice").addColumns("Price"))
        .addIndex(new IndexBuilder("ByRatio").addColumns("Ratio"))
        .addIndex(new IndexBuilder("ByWhen").addColumns("When"))
        .addIndex(new IndexBuilder("ByFlag").addColumns("Flag"))
        .addIndex(new IndexBuilder("ByCode").addColumns("Code"))
        .addIndex(new IndexBuilder("ByDec").addColumns("Dec"))
        .addIndex(new IndexBuilder("ByDecDesc").addColumns(false, "Dec"))
        .addIndex(new IndexBuilder("ByBin").addColumns("Bin"))
        .addIndex(new IndexBuilder("ByNameDescAmount").addColumns(false, "Name").addColumns("Amount"))
        .toTable(db);
    Random r = new Random(42);
    List<Object[]> rows = new ArrayList<>();
    for (int i = 0; i < 2500; i++) {
      String name = r.nextInt(12) == 0 ? null
          : WORDS[r.nextInt(WORDS.length)] + (r.nextBoolean() ? "" : " " + WORDS[r.nextInt(WORDS.length)] + r.nextInt(100));
      byte[] bin = null;
      if (r.nextInt(5) != 0) {
        bin = new byte[r.nextInt(21)];
        r.nextBytes(bin);
      }
      UUID u = new UUID(r.nextLong(), r.nextLong());
      rows.add(new Object[] {
        Column.AUTO_NUMBER, name,
        r.nextInt(10) == 0 ? null : (r.nextDouble() - 0.5) * Math.pow(10, r.nextInt(12) - 4),
        r.nextInt(10) == 0 ? null : (short) (r.nextInt(65536) - 32768),
        (byte) r.nextInt(256),
        new BigDecimal(r.nextInt(2000000) - 1000000).movePointLeft(r.nextInt(5)),
        (float) ((r.nextDouble() - 0.5) * 1000),
        r.nextInt(10) == 0 ? null : LocalDateTime.of(1800 + r.nextInt(300), 1 + r.nextInt(12), 1 + r.nextInt(28),
            r.nextInt(24), r.nextInt(60), r.nextInt(60)),
        r.nextBoolean(),
        r.nextInt(10) == 0 ? null : "{" + u.toString().toUpperCase() + "}",
        r.nextInt(10) == 0 ? null : new BigDecimal(r.nextLong() % 1000000000000L).movePointLeft(3),
        bin
      });
    }
    t.addRows(rows);
  }

  static void writeIndexes(Database db, StringBuilder sb) throws Exception {
    // For every index, the ID column of each row in index order.
    sb.append(",\n  \"indexes\": {");
    boolean first = true;
    for (String tn : new TreeSet<>(db.getTableNames())) {
      Table t = db.getTable(tn);
      Column idCol = null;
      for (Column c : t.getColumns()) if (c.getName().equals("ID")) idCol = c;
      if (idCol == null) continue;
      for (Index idx : t.getIndexes()) {
        sb.append(first ? "\n" : ",\n").append("    ").append(q(tn + "/" + idx.getName())).append(": [");
        first = false;
        boolean firstId = true;
        for (Row row : CursorBuilder.createCursor(idx)) {
          sb.append(firstId ? "" : ",").append(row.get("ID"));
          firstId = false;
        }
        sb.append("]");
      }
    }
    sb.append("\n  }");
  }

  static void writeExpected(File f, Path json) throws Exception {
    StringBuilder sb = new StringBuilder();
    try (Database db = new DatabaseBuilder(f).setReadOnly(true).open()) {
      db.setDateTimeType(DateTimeType.LOCAL_DATE_TIME);
      sb.append("{\n  \"format\": ").append(q(db.getFileFormat().name())).append(",\n  \"tables\": {");
      boolean firstT = true;
      for (String tn : new TreeSet<>(db.getTableNames())) {
        Table t = db.getTable(tn);
        sb.append(firstT ? "\n" : ",\n").append("    ").append(q(tn)).append(": {\n      \"columns\": [");
        firstT = false;
        boolean firstC = true;
        for (Column c : t.getColumns()) {
          sb.append(firstC ? "" : ", ").append("{\"name\": ").append(q(c.getName()))
            .append(", \"type\": ").append(q(c.getType().name())).append("}");
          firstC = false;
        }
        sb.append("],\n      \"rows\": [");
        boolean firstR = true;
        for (Row r : t) {
          sb.append(firstR ? "\n        [" : ",\n        [");
          firstR = false;
          boolean firstV = true;
          for (Column c : t.getColumns()) {
            sb.append(firstV ? "" : ", ").append(val(r.get(c.getName())));
            firstV = false;
          }
          sb.append("]");
        }
        sb.append("\n      ]\n    }");
      }
      sb.append("\n  }");
      writeIndexes(db, sb);
      sb.append("\n}\n");
    }
    Files.write(json, sb.toString().getBytes(StandardCharsets.UTF_8));
  }

  static String val(Object v) {
    if (v == null) return "null";
    if (v instanceof Boolean) return v.toString();
    if (v instanceof Float) return new BigDecimal(Float.toString((Float) v)).toString();
    if (v instanceof Number && !(v instanceof BigDecimal)) return v.toString();
    if (v instanceof BigDecimal) return q(((BigDecimal) v).toPlainString());
    if (v instanceof LocalDateTime) return q(v.toString());
    if (v instanceof byte[]) {
      StringBuilder h = new StringBuilder("hex:");
      for (byte b : (byte[]) v) h.append(String.format("%02x", b));
      return q(h.toString());
    }
    return q(v.toString());
  }

  static String q(String s) {
    StringBuilder b = new StringBuilder("\"");
    for (char ch : s.toCharArray()) {
      switch (ch) {
        case '"': b.append("\\\""); break;
        case '\\': b.append("\\\\"); break;
        case '\n': b.append("\\n"); break;
        case '\r': b.append("\\r"); break;
        case '\t': b.append("\\t"); break;
        default:
          if (ch < 0x20) b.append(String.format("\\u%04x", (int) ch)); else b.append(ch);
      }
    }
    return b.append('"').toString();
  }
}
