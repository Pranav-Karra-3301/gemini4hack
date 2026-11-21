// Event bus shared by the camera UI and the engines. Owned by the lead: don't add or rename
// event types without updating CAM_CONTRACT.md.
//
// Engine -> UI (detail always carries `source`: 'live' | 'decide' | 'mock'):
//   move      {dir, strength, conf}         dir: left|right|up|down|closer|back|rotate_left|rotate_right|hold
//                                           (camera move in RAW frame space; the UI mirrors left/right
//                                           and rotate_* for a mirrored selfie preview)
//   settings  {mode?, zoom?, exposure?, warmth?, iso?, shutter?, focus?, flash?}
//   intent    {intent, conf, subject?}      intent: portrait|group|landscape|object|food|street|document|other
//   reaction  {reaction, conf, heard?}      reaction: pleased|disappointed|neutral
//   ready     {p}                           probability the frame is ready to shoot, 0..1
//   say       {text}                        what the coach says (caption; audio is the engine's job)
//   heard     {text}                        what the user said (transcript)
//   capture   {reason}                      take the photo now
//   speaking  {on}                          coach audio is playing
//   status    {state, detail?}              state: connecting|live|thinking|idle|error
//   stats     {name, ms}                    latency samples for the ?debug=1 overlay
//
// UI -> engine (source 'ui'):
//   ui:captured  {blob}                     a photo was taken
//   ui:settings  {...partial CamState}      the user changed a setting by hand
//   ui:voice     {on}                       audio cues toggled

export const MOVES = ['left', 'right', 'up', 'down', 'closer', 'back', 'rotate_left', 'rotate_right', 'hold'];
export const INTENTS = ['portrait', 'group', 'landscape', 'object', 'food', 'street', 'document', 'other'];
export const REACTIONS = ['pleased', 'disappointed', 'neutral'];
export const MODES = ['photo', 'portrait', 'night', 'macro'];

export function createBus() {
  const target = new EventTarget();
  return {
    emit(type, detail = {}) {
      target.dispatchEvent(new CustomEvent(type, { detail }));
    },
    on(type, fn) {
      const h = (e) => fn(e.detail);
      target.addEventListener(type, h);
      return () => target.removeEventListener(type, h);
    },
  };
}
