double __cdecl _copysign(double x, double y);
float __cdecl copysignf(float x, float y){ return (float)_copysign((double)x,(double)y); }
float __cdecl _copysignf(float x, float y){ return (float)_copysign((double)x,(double)y); }
double __cdecl floor(double x){ long long i=(long long)x; double d=(double)i; return d>x?d-1.0:d; }
float __cdecl floorf(float x){ return (float)floor((double)x); }
