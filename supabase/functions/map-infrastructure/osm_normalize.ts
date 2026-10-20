type Element = { type: string; id: number; lat?: number; lon?: number; tags?: Record<string,string>; geometry?: {lat:number;lon:number}[] };
export function normalize(elements: Element[], categories: string[]) {
  const positive = (v?: string) => !!v && !['no','none','separate','unknown'].includes(v);
  const items = new Map<string, unknown>();
  const crossingNodes = elements.filter(e => e.type === 'node' && e.tags?.highway === 'crossing');
  for (const e of elements) {
    const t = e.tags ?? {};
    if (t.access === 'private' || t.foot === 'no' && t.bicycle === 'no') continue;
    const points = e.geometry?.map(p => [p.lon,p.lat]) ?? (e.lat !== undefined && e.lon !== undefined ? [[e.lon,e.lat]] : []);
    if (!points.length) continue;
    const types: string[] = [];
    if (t.highway === 'crossing' || t.highway === 'footway' && t.footway === 'crossing') {
      // A mapped crossing node and its connecting way describe one crossing.
      const covered = e.type !== 'node' && crossingNodes.some(n => points.some(p => Math.hypot((p[0]-n.lon!) * Math.cos(n.lat! * Math.PI/180), p[1]-n.lat!) < 0.00012));
      if (!covered) types.push('crossing');
    }
    if (t.foot !== 'no' && (t.footway === 'sidewalk' || Object.entries(t).some(([k,v]) => /^sidewalk(:left|:right|:both)?$/.test(k) && positive(v)))) types.push('sidewalk');
    if (t.foot !== 'no' && ['footway','path','pedestrian'].includes(t.highway) && !['sidewalk','crossing'].includes(t.footway)) types.push('walkingPath');
    if (t.bicycle !== 'no' && (t.highway === 'cycleway' || t.highway === 'path' && t.bicycle === 'designated')) types.push('bikePath');
    const cycleValues = Object.entries(t).filter(([k]) => /^cycleway(:left|:right|:both)?$/.test(k)).map(([,v]) => v);
    if (t.bicycle !== 'no' && cycleValues.some(v => ['track','opposite_track'].includes(v))) types.push('bikePath');
    if (t.bicycle !== 'no' && cycleValues.some(v => ['lane','opposite_lane','shared_lane','share_busway'].includes(v))) types.push('bikeLane');
    for (const category of new Set(types.filter(c => categories.includes(c)))) {
      const id = `${e.type}/${e.id}/${category}`;
      const center = points[Math.floor(points.length/2)];
      items.set(id, { id, category, tags: Object.fromEntries(Object.entries(t).filter(([k]) => ['name','highway','footway','crossing','crossing:signals','crossing:markings','wheelchair','tactile_paving','bicycle','foot'].includes(k))),
        geometry: category === 'crossing' || points.length === 1 ? {type:'Point',coordinates:center} : {type:'LineString',coordinates:points} });
    }
  }
  return [...items.values()];
}

