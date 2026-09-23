#ifndef SATELLITE_SGP4_H
#define SATELLITE_SGP4_H

typedef struct {
    double epochJD, epochFraction;
    double meanMotion, eccentricity, inclination, ascendingNode;
    double argumentOfPericenter, meanAnomaly, bstar, meanMotionDot, meanMotionDDot;
} SATElements;

typedef struct { double x, y, z, vx, vy, vz; } SATState;

/// Independent, stack-local initialization makes calls thread safe and order independent.
/// Output is TEME km and km/s. Input angles are degrees; motion is revolutions/day.
int sat_propagate(SATElements elements, double minutesSinceEpoch, SATState *result);
#endif
