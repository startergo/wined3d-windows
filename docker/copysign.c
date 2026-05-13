/* Static copysign replacement — avoids importing _copysign from msvcrt.dll
 * (not available in Win98's VC6-era msvcrt.dll) */
double _copysign(double x, double y)
{
    union { double d; unsigned u[2]; } ux = {x}, uy = {y};
    ux.u[1] = (ux.u[1] & 0x7fffffffu) | (uy.u[1] & 0x80000000u);
    return ux.d;
}
