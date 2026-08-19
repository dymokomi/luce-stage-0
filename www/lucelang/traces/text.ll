; ModuleID = '/Users/sedov/Dev/luciaos/www/lucelang/examples/text.luc'
source_filename = "/Users/sedov/Dev/luciaos/www/lucelang/examples/text.luc"
target triple = "arm64-apple-darwin24.6.0"

@luce.text.0 = private unnamed_addr constant [0 x i8] zeroinitializer
@luce.text.1 = private unnamed_addr constant [21 x i8] c"null object reference"
@luce.text.2 = private unnamed_addr constant [22 x i8] c"object used after free"
@luce.text.3 = private unnamed_addr constant [11 x i8] c"arguments: "
@luce.text.4 = private unnamed_addr constant [24 x i8] c"host service unavailable"
@luce.text.5 = private unnamed_addr constant [4 x i8] c"main"
@luce.text.6 = private unnamed_addr constant [55 x i8] c"/Users/sedov/Dev/luciaos/www/lucelang/examples/text.luc"
@luce.origins.0 = private constant [17 x { i32, i32 }] [{ i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 2, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 3, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }, { i32, i32 } { i32 4, i32 5 }]
@luce.functions = private constant [1 x { ptr, i64, ptr, i64, ptr, i64 }] [{ ptr, i64, ptr, i64, ptr, i64 } { ptr @luce.text.5, i64 4, ptr @luce.text.6, i64 55, ptr @luce.origins.0, i64 17 }]
@luce.text.7 = private unnamed_addr constant [19 x i8] c"call depth exceeded"
@luce_artifact = constant { i64, i64, i64, i32, i32, i32, i32, { i32, [52 x i8] } } { i64 23734338332087628, i64 0, i64 -7092229304759745108, i32 3, i32 29, i32 1, i32 0, { i32, [52 x i8] } { i32 18, [52 x i8] c"aarch64-macos-none\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00\00" } }

define internal i32 @luce.0.main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0, ptr align 8 nocapture nonnull noundef %1, i64 noundef %2, i64 %3) {
4:
  %5 = alloca i64, align 8
  %6 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %7 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %8 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %9 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  store i64 %3, ptr %5, align 8
  %10 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 0
  store i8 4, ptr %10, align 1
  %11 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 1
  store i8 -1, ptr %11, align 1
  %12 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %13 = ptrtoint ptr %12 to i64
  %14 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 3
  store i64 %13, ptr %14, align 8
  %15 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %16 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %6, i32 0, i32 4
  store i64 %15, ptr %16, align 8
  %17 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 0
  store i8 4, ptr %17, align 1
  %18 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 1
  store i8 -1, ptr %18, align 1
  %19 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %20 = ptrtoint ptr %19 to i64
  %21 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  store i64 %20, ptr %21, align 8
  %22 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %23 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 4
  store i64 %22, ptr %23, align 8
  %24 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 0
  store i8 4, ptr %24, align 1
  %25 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 1
  store i8 -1, ptr %25, align 1
  %26 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %27 = ptrtoint ptr %26 to i64
  %28 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 3
  store i64 %27, ptr %28, align 8
  %29 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %30 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %8, i32 0, i32 4
  store i64 %29, ptr %30, align 8
  %31 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 0
  store i8 4, ptr %31, align 1
  %32 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  store i8 -1, ptr %32, align 1
  %33 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 0
  %34 = ptrtoint ptr %33 to i64
  %35 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  store i64 %34, ptr %35, align 8
  %36 = extractvalue { ptr, i64 } { ptr @luce.text.0, i64 0 }, 1
  %37 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  store i64 %36, ptr %37, align 8
  %38 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %39 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 0
  store i8 2, ptr %39, align 1
  %40 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 4
  store i64 0, ptr %40, align 8
  %41 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %42 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %43 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %42, i32 0, i32 0
  store i8 4, ptr %43, align 1
  %44 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %42, i32 0, i32 1
  store i8 -1, ptr %44, align 1
  %45 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %46 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 0
  store i8 4, ptr %46, align 1
  %47 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 1
  store i8 -1, ptr %47, align 1
  %48 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %49 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %50 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  br label %51

51:
  %52 = load i64, ptr %5, align 8
  %53 = trunc i64 %52 to i32
  %54 = lshr i64 %52, 32
  %55 = trunc i64 %54 to i32
  %56 = icmp eq i32 %53, -1
  br i1 %56, label %57, label %60, !prof !0

57:
  %58 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 0
  %59 = extractvalue { ptr, i64 } { ptr @luce.text.1, i64 21 }, 1
  call void @luce_rt_raise(ptr %1, i32 14, ptr %58, i64 %59)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

60:
  %61 = getelementptr inbounds i8, ptr %1, i64 96
  %62 = load ptr, ptr %61, align 8!alias.scope !1, !noalias !2
  %63 = zext i32 %53 to i64
  %64 = mul nsw i64 %63, 112
  %65 = getelementptr inbounds i8, ptr %62, i64 %64
  %66 = getelementptr inbounds i8, ptr %65, i64 96
  %67 = load i32, ptr %66, align 4, !alias.scope !1, !noalias !2
  %68 = icmp ne i32 %67, %55
  br i1 %68, label %69, label %72, !prof !0

69:
  %70 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %71 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %70, i64 %71)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

72:
  %73 = and i32 %67, 1
  %74 = icmp ne i32 %73, 0
  br i1 %74, label %75, label %78, !prof !0

75:
  %76 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 0
  %77 = extractvalue { ptr, i64 } { ptr @luce.text.2, i64 22 }, 1
  call void @luce_rt_raise(ptr %1, i32 13, ptr %76, i64 %77)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 1)
  ret i32 1

78:
  %79 = getelementptr inbounds i8, ptr %65, i64 16
  %80 = load i64, ptr %79, align 8!alias.scope !1, !noalias !2
  %81 = load ptr, ptr %65, align 8, !alias.scope !1, !noalias !2
  %82 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %38, i32 0, i32 3
  store i64 %80, ptr %82, align 8
  %83 = call i32 @luce_rt_str(ptr %1, ptr %38, ptr %41)
  %84 = icmp ne i32 %83, 0
  br i1 %84, label %85, label %86, !prof !0

85:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 2)
  ret i32 1

86:
  %87 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 3
  %88 = load i64, ptr %87, align 8
  %89 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 1
  %90 = load i8, ptr %89, align 1
  %91 = icmp eq i8 %90, -1
  %92 = inttoptr i64 %88 to ptr
  %93 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 2
  %94 = select i1 %91, ptr %92, ptr %93
  %95 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %41, i32 0, i32 4
  %96 = load i64, ptr %95, align 8
  %97 = zext i8 %90 to i64
  %98 = select i1 %91, i64 %96, i64 %97
  %99 = insertvalue { ptr, i64 } poison, ptr %94, 0
  %100 = insertvalue { ptr, i64 } %99, i64 %98, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %7, ptr align 8 %41, i64 24, i1 false)
  %101 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  %102 = load i64, ptr %101, align 8
  %103 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 1
  %104 = load i8, ptr %103, align 1
  %105 = icmp eq i8 %104, -1
  %106 = inttoptr i64 %102 to ptr
  %107 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 2
  %108 = select i1 %105, ptr %106, ptr %107
  %109 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 4
  %110 = load i64, ptr %109, align 8
  %111 = zext i8 %104 to i64
  %112 = select i1 %105, i64 %110, i64 %111
  %113 = insertvalue { ptr, i64 } poison, ptr %108, 0
  %114 = insertvalue { ptr, i64 } %113, i64 %112, 1
  %115 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 11 }, 0
  %116 = ptrtoint ptr %115 to i64
  %117 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %42, i32 0, i32 3
  store i64 %116, ptr %117, align 8
  %118 = extractvalue { ptr, i64 } { ptr @luce.text.3, i64 11 }, 1
  %119 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %42, i32 0, i32 4
  store i64 %118, ptr %119, align 8
  %120 = extractvalue { ptr, i64 } %114, 0
  %121 = ptrtoint ptr %120 to i64
  %122 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 3
  store i64 %121, ptr %122, align 8
  %123 = extractvalue { ptr, i64 } %114, 1
  %124 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %45, i32 0, i32 4
  store i64 %123, ptr %124, align 8
  %125 = call i32 @luce_rt_concat(ptr %1, ptr %42, ptr %45, ptr %48)
  %126 = icmp ne i32 %125, 0
  br i1 %126, label %127, label %128, !prof !0

127:
  call void @luce_rt_unwound(ptr %1, i32 0, i32 6)
  ret i32 1

128:
  %129 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 3
  %130 = load i64, ptr %129, align 8
  %131 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 1
  %132 = load i8, ptr %131, align 1
  %133 = icmp eq i8 %132, -1
  %134 = inttoptr i64 %130 to ptr
  %135 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 2
  %136 = select i1 %133, ptr %134, ptr %135
  %137 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %48, i32 0, i32 4
  %138 = load i64, ptr %137, align 8
  %139 = zext i8 %132 to i64
  %140 = select i1 %133, i64 %138, i64 %139
  %141 = insertvalue { ptr, i64 } poison, ptr %136, 0
  %142 = insertvalue { ptr, i64 } %141, i64 %140, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %48, i64 24, i1 false)
  %143 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %144 = load i64, ptr %143, align 8
  %145 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  %146 = load i8, ptr %145, align 1
  %147 = icmp eq i8 %146, -1
  %148 = inttoptr i64 %144 to ptr
  %149 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 2
  %150 = select i1 %147, ptr %148, ptr %149
  %151 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  %152 = load i64, ptr %151, align 8
  %153 = zext i8 %146 to i64
  %154 = select i1 %147, i64 %152, i64 %153
  %155 = insertvalue { ptr, i64 } poison, ptr %150, 0
  %156 = insertvalue { ptr, i64 } %155, i64 %154, 1
  %157 = extractvalue { ptr, i64 } %156, 0
  %158 = extractvalue { ptr, i64 } %156, 1
  %159 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 1
  %160 = load ptr, ptr %159, align 8
  %161 = icmp eq ptr %160, null
  br i1 %161, label %162, label %165, !prof !0

162:
  %163 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 0
  %164 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %163, i64 %164)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 9)
  ret i32 1

165:
  %166 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %167 = load ptr, ptr %166, align 8
  %168 = call i32 %160(ptr %167, ptr %157, i64 %158)
  %169 = icmp eq i32 %168, -1
  br i1 %169, label %170, label %171, !prof !0

170:
  call void @luce_rt_exhaust(ptr %1)
  ret i32 1

171:
  %172 = icmp ne i32 %168, 0
  %173 = icmp ne i32 %168, 1
  %174 = and i1 %172, %173
  br i1 %174, label %175, label %178, !prof !0

175:
  %176 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 0
  %177 = extractvalue { ptr, i64 } { ptr @luce.text.4, i64 24 }, 1
  call void @luce_rt_raise(ptr %1, i32 9, ptr %176, i64 %177)
  call void @luce_rt_unwound(ptr %1, i32 0, i32 9)
  ret i32 1

178:
  %179 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 3
  %180 = load i64, ptr %179, align 8
  %181 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 1
  %182 = load i8, ptr %181, align 1
  %183 = icmp eq i8 %182, -1
  %184 = inttoptr i64 %180 to ptr
  %185 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 2
  %186 = select i1 %183, ptr %184, ptr %185
  %187 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %9, i32 0, i32 4
  %188 = load i64, ptr %187, align 8
  %189 = zext i8 %182 to i64
  %190 = select i1 %183, i64 %188, i64 %189
  %191 = insertvalue { ptr, i64 } poison, ptr %186, 0
  %192 = insertvalue { ptr, i64 } %191, i64 %190, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %9, ptr %49)
  %193 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %49, i32 0, i32 3
  %194 = load i64, ptr %193, align 8
  %195 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %49, i32 0, i32 1
  %196 = load i8, ptr %195, align 1
  %197 = icmp eq i8 %196, -1
  %198 = inttoptr i64 %194 to ptr
  %199 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %49, i32 0, i32 2
  %200 = select i1 %197, ptr %198, ptr %199
  %201 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %49, i32 0, i32 4
  %202 = load i64, ptr %201, align 8
  %203 = zext i8 %196 to i64
  %204 = select i1 %197, i64 %202, i64 %203
  %205 = insertvalue { ptr, i64 } poison, ptr %200, 0
  %206 = insertvalue { ptr, i64 } %205, i64 %204, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %9, ptr align 8 %49, i64 24, i1 false)
  %207 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 3
  %208 = load i64, ptr %207, align 8
  %209 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 1
  %210 = load i8, ptr %209, align 1
  %211 = icmp eq i8 %210, -1
  %212 = inttoptr i64 %208 to ptr
  %213 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 2
  %214 = select i1 %211, ptr %212, ptr %213
  %215 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %7, i32 0, i32 4
  %216 = load i64, ptr %215, align 8
  %217 = zext i8 %210 to i64
  %218 = select i1 %211, i64 %216, i64 %217
  %219 = insertvalue { ptr, i64 } poison, ptr %214, 0
  %220 = insertvalue { ptr, i64 } %219, i64 %218, 1
  call void @luce_rt_drop_storage(ptr %1, ptr %7, ptr %50)
  %221 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 3
  %222 = load i64, ptr %221, align 8
  %223 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 1
  %224 = load i8, ptr %223, align 1
  %225 = icmp eq i8 %224, -1
  %226 = inttoptr i64 %222 to ptr
  %227 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 2
  %228 = select i1 %225, ptr %226, ptr %227
  %229 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %50, i32 0, i32 4
  %230 = load i64, ptr %229, align 8
  %231 = zext i8 %224 to i64
  %232 = select i1 %225, i64 %230, i64 %231
  %233 = insertvalue { ptr, i64 } poison, ptr %228, 0
  %234 = insertvalue { ptr, i64 } %233, i64 %232, 1
  call void @llvm.memcpy.inline.p0.p0.i64(ptr align 8 %7, ptr align 8 %50, i64 24, i1 false)
  ret i32 0
}

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_raise(ptr nocapture nonnull noundef %0, i32 %1, ptr nocapture readonly %2, i64 %3) #0

; Function Attrs: nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_unwound(ptr nocapture nonnull noundef %0, i32 %1, i32 %2) #0

; Function Attrs: nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_str(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #1

; Function Attrs: nounwind willreturn nofree nocallback memory(argmem: readwrite)
declare void @llvm.memcpy.inline.p0.p0.i64(ptr noalias nocapture writeonly %0, ptr noalias nocapture readonly %1, i64 %2, i1 immarg %3) #2

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare i32 @luce_rt_concat(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %2, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %3) #3

; Function Attrs: nounwind cold willreturn memory(argmem: write)
declare void @luce_rt_exhaust(ptr nocapture nonnull noundef %0) #4

; Function Attrs: nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite)
declare void @luce_rt_drop_storage(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %2) #3

define i32 @luce_main(ptr align 8 nocapture readonly nonnull dereferenceable(472) noundef %0) {
1:
  %2 = alloca i64, align 8
  %3 = alloca i32, align 8
  store i64 256, ptr %2, align 8
  %4 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 0
  %5 = load ptr, ptr %4, align 8
  %6 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 14
  %7 = load ptr, ptr %6, align 8
  %8 = icmp eq ptr %7, null
  br i1 %8, label %11, label %9

9:
  %10 = call i64 %7(ptr %5)
  store i64 %10, ptr %2, align 8
  br label %11

11:
  %12 = load i64, ptr %2, align 8
  %13 = call ptr @luce_rt_open(ptr @luce.functions, i64 1)
  %14 = icmp eq ptr %13, null
  br i1 %14, label %15, label %16, !prof !0

15:
  ret i32 2

16:
  %17 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 28
  %18 = load ptr, ptr %17, align 8
  %19 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 54
  %20 = load ptr, ptr %19, align 8
  %21 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 55
  %22 = load ptr, ptr %21, align 8
  %23 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 56
  %24 = load ptr, ptr %23, align 8
  %25 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 57
  %26 = load ptr, ptr %25, align 8
  %27 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 58
  %28 = load ptr, ptr %27, align 8
  %29 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 29
  %30 = load ptr, ptr %29, align 8
  %31 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 30
  %32 = load ptr, ptr %31, align 8
  %33 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 31
  %34 = load ptr, ptr %33, align 8
  %35 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 32
  %36 = load ptr, ptr %35, align 8
  call void @luce_rt_files_install(ptr %13, ptr %5, ptr %18, ptr %20, ptr %22, ptr %24, ptr %26, ptr %28, ptr %30, ptr %32, ptr %34, ptr %36)
  %37 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 48
  %38 = load ptr, ptr %37, align 8
  %39 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 49
  %40 = load ptr, ptr %39, align 8
  %41 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 50
  %42 = load ptr, ptr %41, align 8
  %43 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 51
  %44 = load ptr, ptr %43, align 8
  %45 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 52
  %46 = load ptr, ptr %45, align 8
  call void @luce_rt_sockets_install(ptr %13, ptr %5, ptr %38, ptr %40, ptr %42, ptr %44, ptr %46)
  %47 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 40
  %48 = load ptr, ptr %47, align 8
  %49 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 41
  %50 = load ptr, ptr %49, align 8
  %51 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 42
  %52 = load ptr, ptr %51, align 8
  %53 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 43
  %54 = load ptr, ptr %53, align 8
  %55 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 44
  %56 = load ptr, ptr %55, align 8
  %57 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 45
  %58 = load ptr, ptr %57, align 8
  %59 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 46
  %60 = load ptr, ptr %59, align 8
  %61 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 47
  %62 = load ptr, ptr %61, align 8
  call void @luce_rt_graphics_install(ptr %13, ptr %5, ptr %48, ptr %50, ptr %52, ptr %54, ptr %56, ptr %58, ptr %60, ptr %62)
  %63 = icmp slt i64 %12, 1
  br i1 %63, label %64, label %65, !prof !0

64:
  call void @luce_rt_raise(ptr %13, i32 6, ptr @luce.text.7, i64 19)
  store i32 1, ptr %3, align 8
  br label %73

65:
  %66 = alloca { i8, i8, [6 x i8], i64, i64 }, align 8
  %67 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 4
  %68 = load ptr, ptr %67, align 8
  %69 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 5
  %70 = load ptr, ptr %69, align 8
  %71 = call i32 @luce_rt_args_list(ptr %13, ptr %5, ptr %68, ptr %70, ptr %66)
  %72 = icmp ne i32 %71, 0
  br i1 %72, label %77, label %78, !prof !0

73:
  %74 = load i32, ptr %3, align 8
  %75 = icmp eq i32 %74, 1
  %76 = icmp eq i32 %74, 2
  br i1 %75, label %83, label %86, !prof !0

77:
  store i32 1, ptr %3, align 8
  br label %73

78:
  %79 = getelementptr inbounds { i8, i8, [6 x i8], i64, i64 }, ptr %66, i32 0, i32 3
  %80 = load i64, ptr %79, align 8
  %81 = call i32 @luce.0.main(ptr %0, ptr %13, i64 %12, i64 %80)
  store i32 %81, ptr %3, align 8
  %82 = call i32 @luce_rt_release(ptr %13, ptr %66)
  br label %73

83:
  %84 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 2
  %85 = load ptr, ptr %84, align 8
  call void @luce_rt_report(ptr %13, ptr %5, ptr %85)
  br label %86

86:
  br i1 %76, label %87, label %90, !prof !0

87:
  %88 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 15
  %89 = load ptr, ptr %88, align 8
  call void @luce_rt_report_error(ptr %13, ptr %5, ptr %89)
  br label %90

90:
  %91 = call i32 @luce_rt_status(ptr %13, i32 %74)
  %92 = icmp eq i32 %91, 2
  %93 = getelementptr inbounds { ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr, ptr }, ptr %0, i32 0, i32 3
  %94 = load ptr, ptr %93, align 8
  %95 = icmp eq ptr %94, null
  %96 = or i1 %95, %92
  br i1 %96, label %97, label %98

97:
  call void @luce_rt_close(ptr %13)
  ret i32 %91

98:
  %99 = call i64 @luce_rt_leaked(ptr %13)
  call void %94(ptr %5, i64 %99)
  br label %97
}

; Function Attrs: nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite)
declare noalias ptr @luce_rt_open(ptr readonly %0, i64 %1) #5

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_files_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9, ptr %10, ptr %11) #6

; Function Attrs: nounwind willreturn memory(readwrite)
declare void @luce_rt_sockets_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6) #7

; Function Attrs: nounwind willreturn memory(argmem: readwrite)
declare void @luce_rt_graphics_install(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr %4, ptr %5, ptr %6, ptr %7, ptr %8, ptr %9) #6

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_args_list(ptr nocapture nonnull noundef %0, ptr %1, ptr %2, ptr %3, ptr align 8 nocapture nonnull dereferenceable(24) writeonly noundef %4) #8

; Function Attrs: nounwind memory(readwrite)
declare i32 @luce_rt_release(ptr nocapture nonnull noundef %0, ptr align 8 nocapture readonly nonnull dereferenceable(24) noundef %1) #8

; Function Attrs: cold
declare void @luce_rt_report(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #9

; Function Attrs: cold
declare void @luce_rt_report_error(ptr nocapture nonnull noundef %0, ptr %1, ptr %2) #9

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i32 @luce_rt_status(ptr nocapture nonnull noundef %0, i32 %1) #10

; Function Attrs: nounwind willreturn memory(argmem: read)
declare i64 @luce_rt_leaked(ptr nocapture nonnull noundef %0) #10

; Function Attrs: nounwind memory(readwrite)
declare void @luce_rt_close(ptr nocapture nonnull noundef %0) #8

attributes #0 = { nounwind cold willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #1 = { nounwind willreturn memory(read, argmem: readwrite, inaccessiblemem: readwrite) }
attributes #2 = { nounwind willreturn nofree nocallback memory(argmem: readwrite) }
attributes #3 = { nounwind willreturn memory(argmem: readwrite, inaccessiblemem: readwrite) }
attributes #4 = { nounwind cold willreturn memory(argmem: write) }
attributes #5 = { nounwind willreturn memory(argmem: read, inaccessiblemem: readwrite) }
attributes #6 = { nounwind willreturn memory(argmem: readwrite) }
attributes #7 = { nounwind willreturn memory(readwrite) }
attributes #8 = { nounwind memory(readwrite) }
attributes #9 = { cold }
attributes #10 = { nounwind willreturn memory(argmem: read) }

!0 = !{!"branch_weights", i32 1, i32 2000}
!1 = !{!3}
!2 = !{!4}
!3 = !{!"luce.rows", !5}
!4 = !{!"luce.elements", !5}
!5 = !{!"luce.alias"}
