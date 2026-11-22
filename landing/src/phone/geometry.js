// The page's iPhone as numbers, shared by the CSS phone (phone.js) and the footer's WebGL phones.
// Everything is in screen widths. The screen has the real screenshots' aspect and the real display's
// corner radius (SCREEN in config.js: 1178 x 2556 px, 55 of 393 pt), so nothing is ever cropped.
import { SCREEN } from '../config.js';

const aspect = SCREEN.w / SCREEN.h; // screen width / height
const radius = SCREEN.radius / SCREEN.pt.w; // corner radius, in screen widths (~0.140)
const bezel = 0.042; // bezel, in screen widths

export const PHONE_GEO = {
  aspect,
  radius,
  bezel,
  frame: { w: 1 + 2 * bezel, h: 1 / aspect + 2 * bezel },
  outerRadius: radius + bezel,
  island: { w: 0.31, h: 0.094, top: 0.029 },
  edge: 0.0045, // the titanium band, for drawings without CSS pixels
  // Side buttons as [side, top, length] in % of the phone's height (iPhone 15 Pro), and how far
  // they stand out, in screen widths.
  buttons: [
    ['l', 17.2, 5.4], // action
    ['l', 25.4, 8.9], // volume up
    ['l', 36.0, 8.9], // volume down
    ['r', 27.0, 13.6], // side
  ],
  buttonDepth: 0.0065,
};

