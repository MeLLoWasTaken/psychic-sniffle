extends RefCounted
## A fixed arena layout for movement, gate and line-of-sight unit tests, so they test the rules
## rather than the current design of a real map (real maps have their own tests in test_map.gd).
## 40 m square, pillars at (+-7, +-7), a central block, full-width gates at x = +-15.


static func map() -> Dictionary:
	return {
		 "id": "test_fixture",
		 "bounds_half_m": 20,
		 "spawns": {
		  "team_a": [
		   [
		    -18,
		    0,
		    -2
		   ],
		   [
		    -18,
		    0,
		    2
		   ],
		   [
		    -18,
		    0,
		    0
		   ]
		  ],
		  "team_b": [
		   [
		    18,
		    0,
		    -2
		   ],
		   [
		    18,
		    0,
		    2
		   ],
		   [
		    18,
		    0,
		    0
		   ]
		  ]
		 },
		 "colliders": [
		  {
		   "type": "circle",
		   "center": [
		    -7,
		    -7
		   ],
		   "radius": 1.2,
		   "blocks_los": true
		  },
		  {
		   "type": "circle",
		   "center": [
		    7,
		    -7
		   ],
		   "radius": 1.2,
		   "blocks_los": true
		  },
		  {
		   "type": "circle",
		   "center": [
		    -7,
		    7
		   ],
		   "radius": 1.2,
		   "blocks_los": true
		  },
		  {
		   "type": "circle",
		   "center": [
		    7,
		    7
		   ],
		   "radius": 1.2,
		   "blocks_los": true
		  },
		  {
		   "type": "box",
		   "min": [
		    -2.5,
		    -2.5
		   ],
		   "max": [
		    2.5,
		    2.5
		   ],
		   "height": 3.5,
		   "blocks_los": true
		  },
		  {
		   "type": "box",
		   "min": [
		    -15.5,
		    -20
		   ],
		   "max": [
		    -14.5,
		    20
		   ],
		   "height": 5,
		   "blocks_los": true,
		   "gate": true
		  },
		  {
		   "type": "box",
		   "min": [
		    14.5,
		    -20
		   ],
		   "max": [
		    15.5,
		    20
		   ],
		   "height": 5,
		   "blocks_los": true,
		   "gate": true
		  }
		 ]
		}


static func geometry() -> ArenaGeometry:
	return ArenaGeometry.from_map(map())
