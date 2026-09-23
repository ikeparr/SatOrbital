#include "include/SatelliteSGP4.h"
#include "SGP4.h"
#include <math.h>

int sat_propagate(SATElements e, double minutes, SATState *result) {
    ElsetRec record = {0};
    record.whichconst = wgs72;
    record.jdsatepoch = e.epochJD;
    record.jdsatepochF = e.epochFraction;
    record.bstar = e.bstar;
    record.ecco = e.eccentricity;
    record.inclo = e.inclination * deg2rad;
    record.nodeo = e.ascendingNode * deg2rad;
    record.argpo = e.argumentOfPericenter * deg2rad;
    record.mo = e.meanAnomaly * deg2rad;
    const double xpdotp = 1440.0 / twopi;
    record.no_kozai = e.meanMotion / xpdotp;
    record.ndot = e.meanMotionDot / (xpdotp * 1440.0);
    record.nddot = e.meanMotionDDot / (xpdotp * 1440.0 * 1440.0);
    if (!sgp4init('a', &record) || record.error) return record.error ? record.error : -1;
    double r[3], v[3];
    if (!sgp4(&record, minutes, r, v) || record.error) return record.error ? record.error : -1;
    for (int i = 0; i < 3; i++) if (!isfinite(r[i]) || !isfinite(v[i])) return -2;
    *result = (SATState){r[0], r[1], r[2], v[0], v[1], v[2]};
    return 0;
}
