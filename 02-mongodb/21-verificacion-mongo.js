// =====================================================================
// ITI-821 | Escenario 8: Turismo Inteligente | Semana 3
// Integrante 1: Alex Herrera
// ---------------------------------------------------------------------
// 21-verificacion-mongo.js
//
// Fotografia de la fuente MongoDB ANTES de correr el ETL. Los conteos que
// produce son los valores esperados que se contrastan despues contra
// dw.FactResena y dw.FactInteraccionWeb.
//
// Uso:
//   mongosh --quiet --file 21-verificacion-mongo.js
// =====================================================================

const db = db.getSiblingDB("turismo_nosql");

function titulo(t) {
  print("");
  print("=== " + t + " ===");
}

function n(x) {
  return x.toLocaleString("en-US");
}

// ---------------------------------------------------------------------
titulo("1. Conteo de documentos por coleccion");

const nResenas = db.resenas.countDocuments();
const nInteracciones = db.interacciones_web.countDocuments();

print("  resenas            : " + n(nResenas));
print("  interacciones_web  : " + n(nInteracciones));

if (nResenas === 0) {
  print("");
  print("  AVISO: no hay datos. Ejecute antes 20-seed_resenas.py");
}

// ---------------------------------------------------------------------
titulo("2. Distribucion de calificaciones (base del KPI de satisfaccion)");

db.resenas
  .aggregate([
    { $group: { _id: "$calificacion", total: { $sum: 1 } } },
    { $sort: { _id: -1 } },
  ])
  .forEach((d) => {
    const pct = ((100 * d.total) / nResenas).toFixed(2);
    print("  " + d._id + " estrellas : " + n(d.total).padStart(10) + "  (" + pct + " %)");
  });

const prom = db.resenas
  .aggregate([
    {
      $group: {
        _id: null,
        promedio: { $avg: "$calificacion" },
        positivas: { $sum: { $cond: [{ $gte: ["$calificacion", 4] }, 1, 0] } },
        verificadas: { $sum: { $cond: ["$verificada", 1, 0] } },
      },
    },
  ])
  .toArray()[0];

if (prom) {
  print("");
  print("  Calificacion promedio    : " + prom.promedio.toFixed(4));
  print("  Resenas positivas (>=4)  : " + n(prom.positivas) +
        "  (" + ((100 * prom.positivas) / nResenas).toFixed(2) + " %)");
  print("  Resenas verificadas      : " + n(prom.verificadas) +
        "  (" + ((100 * prom.verificadas) / nResenas).toFixed(2) + " %)");
}

// ---------------------------------------------------------------------
titulo("3. Resenas por tipo de entidad");

db.resenas
  .aggregate([
    { $group: { _id: "$tipo_entidad", total: { $sum: 1 } } },
    { $sort: { total: -1 } },
  ])
  .forEach((d) => print("  " + String(d._id).padEnd(10) + n(d.total).padStart(10)));

// ---------------------------------------------------------------------
titulo("4. Cobertura temporal");

const rango = db.resenas
  .aggregate([
    { $group: { _id: null, min: { $min: "$fecha" }, max: { $max: "$fecha" } } },
  ])
  .toArray()[0];

if (rango) {
  print("  resenas            : " + rango.min.toISOString().slice(0, 10) +
        "  ..  " + rango.max.toISOString().slice(0, 10));
}

const rangoInt = db.interacciones_web
  .aggregate([
    { $group: { _id: null, min: { $min: "$fecha_evento" }, max: { $max: "$fecha_evento" } } },
  ])
  .toArray()[0];

if (rangoInt) {
  print("  interacciones_web  : " + rangoInt.min.toISOString().slice(0, 10) +
        "  ..  " + rangoInt.max.toISOString().slice(0, 10));
}

// ---------------------------------------------------------------------
titulo("5. Interacciones web por tipo de evento");

db.interacciones_web
  .aggregate([
    { $group: { _id: "$tipo_evento", total: { $sum: 1 } } },
    { $sort: { total: -1 } },
  ])
  .forEach((d) => {
    const pct = ((100 * d.total) / nInteracciones).toFixed(2);
    print("  " + String(d._id).padEnd(22) + n(d.total).padStart(10) + "  (" + pct + " %)");
  });

const conv = db.interacciones_web.countDocuments({ convirtio: true });
print("");
print("  Conversiones : " + n(conv) +
      "  (" + ((100 * conv) / nInteracciones).toFixed(2) + " %)");

const anon = db.interacciones_web.countDocuments({ cliente_id: null });
print("  Sesiones anonimas : " + n(anon) +
      "  (" + ((100 * anon) / nInteracciones).toFixed(2) + " %)");

// ---------------------------------------------------------------------
titulo("6. Calidad: documentos que la validacion del ETL deberia rechazar");

const fueraRango = db.resenas.countDocuments({
  $or: [
    { calificacion: { $lt: 1 } },
    { calificacion: { $gt: 5 } },
    { calificacion: { $exists: false } },
  ],
});
print("  Calificaciones fuera de 1..5 : " + n(fueraRango));

const sinEntidad = db.resenas.countDocuments({ entidad_id: null });
print("  Resenas sin entidad asociada : " + n(sinEntidad));

// ---------------------------------------------------------------------
titulo("7. Indices");

["resenas", "interacciones_web"].forEach((c) => {
  print("  " + c + ":");
  db[c].getIndexes().forEach((i) => print("    - " + i.name));
});

// ---------------------------------------------------------------------
titulo("8. Valores esperados para 46-validacion-consistencia.sql");

print("  ResenasOrigen=" + nResenas + " InteraccionesOrigen=" + nInteracciones);
print("");
