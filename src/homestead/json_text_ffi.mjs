export function pretty(value) {
  return JSON.stringify(value, null, 2);
}

export function compact(value) {
  return JSON.stringify(value);
}
