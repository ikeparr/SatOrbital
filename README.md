# SatOrbital

SatOrbital is a *Work In Progress* native iPhone app for exploring Earth while tracking the International Space Station (ISS). It renders an interactive, textured globe and shows the ISS (and eventually all satellites) at its predicted position for the selected time, along with its orbital path and key flight details.

The app calculates the ISS position from current orbital elements and displays its altitude, speed, and latitude and longitude. You can rotate and zoom the globe, pause the displayed time, and return to the current time and ISS position. Orbital data is cached on the device so a previously saved position can be shown offline.

Positions are calculated predictions, not live telemetry, and can differ from the ISS's actual position as orbital data ages or the orbit changes.

The green line is a closed, instantaneous orbital ellipse derived from the ISS's current predicted position and velocity. It refreshes with the position once per second, using one Earth rotation time for the whole ring. The ISS remains positioned by SGP4; the ellipse is a display approximation, not a future ground track. This follows the [state-to-osculating-orbit approach described by NASA/JPL](https://naif.jpl.nasa.gov/pub/naif/toolkit_docs/C/cspice/oscelt_c.html).

This is a personal project, there are currently have no plans to actually TestFlight the app
