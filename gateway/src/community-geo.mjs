export function approximateLocation({ latitude, longitude }) {
  const lat = Math.max(-89.999, Math.min(89.999, Math.round(latitude / 0.0045) * 0.0045));
  const step = Math.min(180, 0.0045 / Math.max(0.000025, Math.cos(lat * Math.PI / 180)));
  const lon = Math.round(longitude / step) * step;
  return { latitude: lat, longitude: (((lon + 180) % 360 + 360) % 360) - 180 };
}
export function distanceMeters(a, b) {
  const rad = Math.PI / 180, lat = (b.latitude - a.latitude) * rad, lon = (b.longitude - a.longitude) * rad;
  const v = Math.sin(lat / 2) ** 2 + Math.cos(a.latitude * rad) * Math.cos(b.latitude * rad) * Math.sin(lon / 2) ** 2;
  return 6371000 * 2 * Math.atan2(Math.sqrt(Math.min(1, v)), Math.sqrt(Math.max(0, 1 - v)));
}
