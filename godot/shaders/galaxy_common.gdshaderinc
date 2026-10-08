// Whole galaxies as volumes: GALV_FS of the web version (index.html, 20-volumes.js), unchanged in what it computes.
// Each galaxy is followed along the ray in its own frame and units (camera position uRo, in galaxy radii), so the
// size of the universe never reaches single precision. Up to MAXG galaxies, composited in the order the web draws
// them (later ones over earlier ones, premultiplied alpha).
#define MAXG 5
#define GSTEPS 128

uniform sampler3D uVol : filter_linear, repeat_enable;
uniform int uCount = 0;
uniform float uSamples = 96.0;
uniform float uDetail = 1.0;
uniform vec3 uRo[MAXG];
uniform vec3 uM0[MAXG];
uniform vec3 uM1[MAXG];
uniform vec3 uM2[MAXG];
uniform vec4 uShape[MAXG];   // arms, b, r0, seed
uniform vec4 uLook[MAXG];    // kind, gain, alpha, -
uniform vec3 uCore[MAXG];
uniform vec3 uArmCol[MAXG];

// F1 and F2: two independent fields of four-octave cloud noise, baked into the 3D texture
float F1(vec3 p){ return textureLod(uVol, p*0.25, 0.0).r*0.9375; }
float F2(vec3 p){ return textureLod(uVol, p*0.25 + 0.37, 0.0).g*0.9375; }

vec4 galaxy_march(int g, vec3 rdw, float dith){
	vec3 uRoG = uRo[g];
	vec3 rd = vec3(dot(uM0[g], rdw), dot(uM1[g], rdw), dot(uM2[g], rdw));
	float uArms = uShape[g].x, uB = uShape[g].y, uR0 = uShape[g].z, uSeed = uShape[g].w;
	float uKind = uLook[g].x, uGain = uLook[g].y, uAlpha = uLook[g].z;
	vec3 core = uCore[g], armCol = uArmCol[g];
	float tEnd = 1e9;
	vec3 so = uRoG*vec3(1.0, 3.2, 1.0); vec3 sd = rd*vec3(1.0, 3.2, 1.0);
	float A = dot(sd, sd); float Bq = dot(so, sd); vec3 cl = so - sd*(Bq/A); float h = A*(1.0 - dot(cl, cl));
	if(h < 0.0) return vec4(0.0);
	h = sqrt(h); float t0 = max((-Bq - h)/A, 0.0); float t1 = min((-Bq + h)/A, tEnd);
	if(t1 <= t0) return vec4(0.0);
	float dt = (t1 - t0)/uSamples; float t = t0 + dt*dith; vec3 col = vec3(0.0); float T = 1.0;
	for(int i = 0; i < GSTEPS; i++){
		if(float(i) >= uSamples) break;
		vec3 p = uRoG + rd*t; float r = length(p.xz); float z = p.y; vec3 em = vec3(0.0); float dust = 0.0;
		if(uKind < 0.5){
			float hz = 0.018 + 0.030*r; float fall = 1.0 - smoothstep(0.80, 1.0, r);
			float vert = exp(-abs(z)/hz); float discR = exp(-r*3.6)*fall;
			float th = atan(p.z, p.x); vec3 q = vec3(p.x, z*2.5, p.z);
			float n0 = F2(q*2.0 + uSeed*1.7);              // slow wobble: no two arms alike
			float n = F1(q*6.0 + uSeed);                   // patches
			float n2 = F2(q*17.0 + n*2.0 + uSeed);         // clumps
			float n3 = F1(q*46.0 + n2*2.0);                // fine grain
			float ph = (log(max(r, 0.002)/uR0)/uB - (th - 3.14159265))/(6.2831853/uArms) + (n0 - 0.47)*1.1 + (n - 0.47)*0.35;
			float d = abs(fract(ph + 0.5) - 0.5)*2.0; float inner = smoothstep(0.06, 0.20, r);
			float broad = exp(-d*d*3.2)*inner; float ridge = exp(-d*d*16.0)*inner;
			// old stars: a smooth warm disc that fills the space between the arms, turning bluer toward the rim
			vec3 oldCol = mix(core, vec3(0.86, 0.88, 1.0), smoothstep(0.15, 0.75, r)*0.55);
			float old = discR*vert*(0.50 + 0.55*broad);
			// young stars: blue and clumpy, hugging the ridges of the arms in a thinner layer; pink where stars are being born
			float thin = exp(-abs(z)/(hz*0.55));
			float yng = pow(discR, 0.75)*thin*(ridge*(0.25 + 3.8*n2*n2) + broad*0.30*n)*(0.55 + 0.9*n0);
			float hii = yng*smoothstep(0.58, 0.74, n3*0.6 + n2*0.5);
			float rr = r*r + z*z*2.4; float bul = exp(-rr*60.0)*0.9 + exp(-rr*14.0)*0.22;
			em = oldCol*old*6.0 + armCol*(yng*9.0 + discR*vert*broad*(0.4 + 1.2*n)*1.5) + vec3(1.0, 0.36, 0.52)*hii*14.0 + core*bul*1.3;
			// dust: a thin sheet in the mid-plane, thickest along the inner edge of each arm and patchy elsewhere
			float dl = abs(fract(ph + 0.63) - 0.5)*2.0; float lane = exp(-dl*dl*22.0)*inner;
			dust = exp(-abs(z)/(hz*0.30))*pow(discR, 0.55)*(lane*(0.5 + 1.3*n2) + 0.22*smoothstep(0.45, 0.70, n))*(0.6 + 0.8*n3)*38.0;
			// the web skips this fetch only where it cannot change the result at float precision
			if(uDetail > 0.6 && (dust*dt > 0.000000001 || dust > 0.00006)){
				float tendril = F2(q*94.0 + n3 + uSeed);
				dust *= mix(1.0, 0.62 + 1.0*smoothstep(0.31, 0.69, tendril), uDetail);
			}
		} else if(uKind < 1.5){
			float rr = r*r + z*z*1.6; em = core*(exp(-rr*9.0)*1.2 + exp(-rr*60.0)*3.0);
		} else {
			vec3 q = p*5.0 + uSeed; float n = F1(q); float n2 = F2(q*2.4);
			float bodyI = exp(-(p.x*p.x*3.0 + z*z*30.0 + p.z*p.z*9.0))*smoothstep(0.3, 0.6, n + 0.15);
			em = armCol*bodyI*3.0 + vec3(1.0, 0.4, 0.55)*bodyI*smoothstep(0.62, 0.8, n2)*8.0 + core*bodyI;
			dust = bodyI*smoothstep(0.5, 0.7, n2)*8.0;
		}
		float tr = exp(-max(dust, 0.0)*dt); float segment = dust > 0.0001 ? (1.0 - tr)/dust : dt;
		col += T*em*segment*3.0*uGain; T *= tr; t += dt;
		if(T < 0.01) break;
	}
	return vec4(col*uAlpha, (1.0 - T)*uAlpha);
}

// all galaxies along one direction, in the web's draw order: rgb is the light, a how much of what is behind is hidden
vec4 galaxies(vec3 rdw, float dith){
	vec4 acc = vec4(0.0);
	for(int g = 0; g < MAXG; g++){
		if(g >= uCount) break;
		vec4 s = galaxy_march(g, rdw, dith);
		acc = s + acc*(1.0 - s.a);
	}
	return acc;
}

float web_dither(vec2 frag){ return fract(52.9829189*fract(0.06711056*frag.x + 0.00583715*frag.y)); }
