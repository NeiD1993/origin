Shader "Legacy Shaders/Lightmapped/VertexLit (Color Instancing)"
{
	Properties
	{
		_Color("Main Color", Color) = (1,1,1,1)
		_SpecColor("Spec Color", Color) = (1,1,1,1)
		[PowerSlider(5.0)]  _Shininess("Shininess", Range(0.01,1)) = 0.7
		_MainTex("Base (RGB)", 2D) = "white" { }
	    _LightMap("Lightmap (RGB)", 2D) = "lightmap" { }
	}
		
	SubShader
	{
		LOD 100

		Tags { "RenderType" = "Opaque" }
		 
		Pass 
	    {
		    Name "BASE"

			Tags { "LIGHTMODE" = "Vertex" "RenderType" = "Opaque" }
		
		    CGPROGRAM

            #pragma vertex vert
            #pragma fragment frag
            #pragma target 2.0
            #include "UnityCG.cginc"
            #pragma multi_compile_fog
            #define USING_FOG (defined(FOG_LINEAR) || defined(FOG_EXP) || defined(FOG_EXP2))

		    // ES2.0/WebGL can not do loops with non-constant-expression iteration counts :(
            #if defined(SHADER_API_GLES)
                #define LIGHT_LOOP_LIMIT 8
            #else
                #define LIGHT_LOOP_LIMIT unity_VertexLightParams.x
            #endif

			// Some ES3 drivers (e.g. older Adreno) have problems with the light loop
            #if defined(SHADER_API_GLES3) && !defined(SHADER_API_DESKTOP) && (defined(SPOT) || defined(POINT))
                #define LIGHT_LOOP_ATTRIBUTE UNITY_UNROLL
            #else
                #define LIGHT_LOOP_ATTRIBUTE
            #endif

            #define ENABLE_SPECULAR 1
			// Compile specialized variants for when positional (point/spot) and spot lights are present
            #pragma multi_compile __ POINT SPOT
            #pragma multi_compile_instancing

			// Compute illumination from one light, given attenuation
		    half3 computeLighting(int idx, half3 dirToLight, half3 eyeNormal, half3 viewDir, half4 diffuseColor, half shininess, half atten, inout half3 specColor) 
	        {
		        half NdotL = max(dot(eyeNormal, dirToLight), 0.0);
				// diffuse
				half3 color = NdotL * diffuseColor.rgb * unity_LightColor[idx].rgb;

				// specular
				if (NdotL > 0.0) 
				{
					half3 h = normalize(dirToLight + viewDir);
					half HdotN = max(dot(eyeNormal, h), 0.0);
					half sp = saturate(pow(HdotN, shininess));
					
					specColor += (atten * sp) * unity_LightColor[idx].rgb;
				}
				
				return color * atten;
	        }

	        // Compute attenuation & illumination from one light
	        half3 computeOneLight(int idx, float3 eyePosition, half3 eyeNormal, half3 viewDir, half4 diffuseColor, half shininess, inout half3 specColor) 
			{
				float3 dirToLight = unity_LightPosition[idx].xyz;
				half att = 1.0;
                
                #if defined(POINT) || defined(SPOT)
				    dirToLight -= eyePosition * unity_LightPosition[idx].w;

					// distance attenuation
					float distSqr = dot(dirToLight, dirToLight);
					
					att /= (1.0 + unity_LightAtten[idx].z * distSqr);
					
					if (unity_LightPosition[idx].w != 0 && distSqr > unity_LightAtten[idx].w) att = 0.0; // set to 0 if outside of range
					
					distSqr = max(distSqr, 0.000001); // don't produce NaNs if some vertex position overlaps with the light
					dirToLight *= rsqrt(distSqr);
                    
                    #if defined(SPOT)
					    // spot angle attenuation
					    half rho = max(dot(dirToLight, unity_SpotDirection[idx].xyz), 0.0);
						half spotAtt = (rho - unity_LightAtten[idx].x) * unity_LightAtten[idx].y;
						
						att *= saturate(spotAtt);
                    #endif
                #endif
						
                att *= 0.5; // passed in light colors are 2x brighter than what used to be in FFP
				
				return min(computeLighting(idx, dirToLight, eyeNormal, viewDir, diffuseColor, shininess, att, specColor), 1.0);
			}

			// uniforms
			half4 _SpecColor;
			half _Shininess;
			int4 unity_VertexLightParams; // x: light count, y: zero, z: one (y/z needed by d3d9 vs loop instruction)
			float4 _LightMap_ST;
			float4 _MainTex_ST;

			// vertex shader input data
			struct appdata 
			{
				float3 pos : POSITION;
				float3 normal : NORMAL;
				float3 uv1 : TEXCOORD1;
				float3 uv0 : TEXCOORD0;
				UNITY_VERTEX_INPUT_INSTANCE_ID
			};

			// vertex-to-fragment interpolators
			struct v2f 
			{
				fixed4 color : COLOR0;
                
                #if ENABLE_SPECULAR
				    fixed3 specColor : COLOR1;
                #endif
					
				float2 uv0 : TEXCOORD0;
				float2 uv1 : TEXCOORD1;
				float2 uv2 : TEXCOORD2;

                #if USING_FOG
				    fixed fog : TEXCOORD3;
                #endif
					
				float4 pos : SV_POSITION;
				UNITY_VERTEX_OUTPUT_STEREO
				UNITY_VERTEX_INPUT_INSTANCE_ID
			};

			UNITY_INSTANCING_BUFFER_START(Props)
				UNITY_DEFINE_INSTANCED_PROP(half4, _Color)
			UNITY_INSTANCING_BUFFER_END(Props)

			// vertex shader
			v2f vert(appdata IN) 
			{
				v2f o;
				
				UNITY_SETUP_INSTANCE_ID(IN);
				UNITY_TRANSFER_INSTANCE_ID(IN, o);
				UNITY_INITIALIZE_VERTEX_OUTPUT_STEREO(o);
				
				half4 color = half4(0,0,0,1.1);
				float3 eyePos = mul(UNITY_MATRIX_MV, float4(IN.pos,1)).xyz;
				half3 eyeNormal = normalize(mul((float3x3)UNITY_MATRIX_IT_MV, IN.normal).xyz);
				half3 viewDir = 0.0;
				
				viewDir = -normalize(eyePos);
				
				// lighting
				half3 lcolor = half4(0,0,0,1).rgb + half4(0,0,0,1).rgb * glstate_lightmodel_ambient.rgb;
				half4 instancedColor = UNITY_ACCESS_INSTANCED_PROP(Props, _Color);
				half3 specColor = 0.0;
				half shininess = _Shininess * 128.0;
				
				LIGHT_LOOP_ATTRIBUTE for (int il = 0; il < LIGHT_LOOP_LIMIT; ++il) 
				{
					lcolor += computeOneLight(il, eyePos, eyeNormal, viewDir, instancedColor, shininess, specColor);
				}
				
				color.rgb = lcolor.rgb;
				color.a = instancedColor.a;
				specColor *= _SpecColor.rgb;
				o.color = saturate(color);
                
                #if ENABLE_SPECULAR
				    o.specColor = saturate(specColor);
                #endif
					
				// compute texture coordinates
				o.uv0 = IN.uv1.xy * _LightMap_ST.xy + _LightMap_ST.zw;
				o.uv1 = IN.uv1.xy * _LightMap_ST.xy + _LightMap_ST.zw;
				o.uv2 = IN.uv0.xy * _MainTex_ST.xy + _MainTex_ST.zw;
				
				// fog
                #if USING_FOG
				    float fogCoord = length(eyePos.xyz); // radial fog distance
					
					UNITY_CALC_FOG_FACTOR_RAW(fogCoord);
					o.fog = saturate(unityFogFactor);
                #endif
					
				// transform position
				o.pos = UnityObjectToClipPos(IN.pos);
				
				return o;
			}

			// textures
			sampler2D _LightMap;
			sampler2D _MainTex;

			// fragment shader
			fixed4 frag(v2f IN) : SV_Target 
			{
				fixed4 col;
			
			    UNITY_SETUP_INSTANCE_ID(IN);
				
				fixed4 tex, tmp0, tmp1, tmp2;
			
				// SetTexture #0
				tex = tex2D(_LightMap, IN.uv0.xy);
				col = tex * UNITY_ACCESS_INSTANCED_PROP(Props, _Color);
				// SetTexture #1
				tex = tex2D(_LightMap, IN.uv1.xy);
				col = col * fixed4(0.5,0.5,0.5,0.5).a + IN.color;
				// SetTexture #2
				tex = tex2D(_MainTex, IN.uv2.xy);
				col.rgb = tex * col;
				col *= 2;
				col.a = fixed4(1,1,1,1).a;

                #if ENABLE_SPECULAR
				    // add specular color
				    col.rgb += IN.specColor;
                #endif
				
				// fog
                #if USING_FOG
					col.rgb = lerp(unity_FogColor.rgb, col.rgb, IN.fog);
                #endif
				
				return col;
			}

			// texenvs
			//! TexEnv0: 01010102 01010102 [_LightMap] [_Color]
			//! TexEnv1: 0100a203 0100a203 [_LightMap] [80808080]
			//! TexEnv2: 02010100 01060004 [_MainTex] [ffffffff]
			ENDCG
        }
	}
	
	Fallback "Legacy Shaders/VertexLit (Color Instancing)"
}