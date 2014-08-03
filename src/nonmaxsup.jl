# NONMAXSUP - Non-maxima suppression
#
# Usage:
#          (im,location) = nonmaxsup(img, gradientangles, radius);
#
# Function for performing non-maxima suppression on an image using
# gradient angles.  Gradient angles are assumed to be in radians.
#
# Input:
#   img - image to be non-maxima suppressed.
# 
#   gradientangles - image containing gradient angles around each pixel in radians
#                    (-pi,pi)
# 
#   radius  - Distance in pixel units to be looked at on each side of each
#             pixel when determining whether it is a local maxima or not.
#             This value cannot be less than 1.
#             (Suggested value about 1.2 - 1.5)
#
# Returns:
#   im        - Non maximally suppressed image.
#   location  - `Graphics.Point` image holding subpixel locations of edge
#               points. 
#
# Notes:
#
# This function uses bilinear interpolation to estimate
# intensity values at ideal, real-valued pixel locations on each side of
# pixels to determine if they are local maxima.

# Copyright (c) 1996-2013 Peter Kovesi
# Centre for Exploration Targeting
# The University of Western Australia
# 
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# The Software is provided "as is", without warranty of any kind.

# December  1996 - Original version
# September 2004 - Subpixel localization added
# August    2005 - Made Octave compatible
# October   2013 - Final thinning applied to binary image for Octave
#                  compatbility (Thanks to Chris Pudney)
# June      2014 - Converted (and modified significantly) to Julia (Kevin Squire)

import Base.Graphics.Point

if !applicable(zero, Point)
    import Base.zero
    zero(Point) = Point(0.0,0.0)
end

# Used to encode the sign, integral, and fractional components of
# an offset from a coordinate
immutable CoordOffset
    s::Int      # sign
    i::Int      # integer part
    f::Float64  # fractional part
end

CoordOffset(x::Float64) = ((frac,i) = modf(x); CoordOffset(sign(frac), int(i), abs(frac)))
(-)(off::CoordOffset) = CoordOffset(-off.s,-off.i, off.f)
(*)(x::Number, off::CoordOffset) = x*(off.i + off.s*off.f)
(*)(off::CoordOffset, x::Number) = x*(off.i + off.s*off.f)
(+)(x::Number, off::CoordOffset) = x + off.i + off.s*off.f
(+)(off::CoordOffset, x::Number) = x + off.i + off.s*off.f

# Precalculate x and y offsets relative to centre pixel for each orientation angle 
function _calc_discrete_offsets(θ, radius, transposed)

    θ_count = iround(2π/θ)
    θ = 2π/θ_count
    angles = (0:θ_count)*θ

    # x and y offset of points at specified radius and angles
    # from each reference position.

    if transposed
        # θ′ = -π/2 - θ
        xoffs = [CoordOffset(-x) for x in  radius*sin(angles)]
        yoffs = [CoordOffset( y) for y in  radius*cos(angles)]
    else
        xoffs = [CoordOffset( x) for x in  radius*cos(angles)]
        yoffs = [CoordOffset(-y) for y in  radius*sin(angles)]
    end

    return θ, xoffs, yoffs
end

_discretize_angle(angle::FloatingPoint, invθ) = 
    angle < 0 ? iround((angle + 2π)*invθ)+1 : iround(angle*invθ)+1

# Interpolate the value of an offset from a particular pixel
#
# Returns (interpolated value, min_value of adjacent pixels in direction of offset)
#
# The second value is made available to eliminate double edges; if the value at
# (x,y) is less than the value or values adjacent to it in the direction of the
# gradient (xoff,yoff), then it is not a local maximum

function _interp_offset(img::AbstractArray, x::Integer, y::Integer, xoff::CoordOffset, yoff::CoordOffset, Ix, Iy, pad)
    fx = Ix[x + xoff.i + pad]
    fy = Iy[y + yoff.i + pad]
    cx = Ix[x + xoff.i + xoff.s + pad]
    cy = Iy[y + yoff.i + yoff.s + pad]

    tl = img[fy,fx]    # Value at bottom left integer pixel location.
    tr = img[fy,cx]    # bottom right
    bl = img[cy,fx]    # top left
    br = img[cy,cx]    # top right

    upperavg = tl + xoff.f * (tr - tl)  # Now use bilinear interpolation to
    loweravg = bl + xoff.f * (br - bl)  # estimate value at x,y

    min_adjacent = (fx == x) & (fy == y) ? min(tr,bl) : tl

    return (upperavg + yoff.f * (loweravg - upperavg), min_adjacent)
end

cv2_count = 0

# Core edge thinning algorithm using nonmaximal suppression
function thin_edges_nonmaxsup_core!{T}(out::AbstractArray{T,2}, location::AbstractArray{Point,2}, 
                                       img::AbstractArray{T,2}, gradientangles, radius, border, theta)
    calc_subpixel = !isempty(location)

    # Error checking
    size(img) == size(gradientangles) == size(out) || error("image, gradient angle, and output image must all be the same size")
    calc_subpixel && size(location) != size(img) && error("subpixel location has a different size than the input image")
    radius < 1.0 && error("radius must be >= 1")

    # Precalculate x and y offsets relative to centre pixel for each orientation angle 
    transposed = spatialorder(img)[1] == "x"
    θ, xoffs, yoffs = _calc_discrete_offsets(theta, radius, transposed)
    iθ = 1/θ

    # Indexes to use for border handling
    pad = iceil(radius)
    Ix = Images.padindexes(img, 2, pad, pad, border)
    Iy = Images.padindexes(img, 1, pad, pad, border)
    
    # Now run through the image interpolating grey values on each side
    # of the centre pixel to be used for the non-maximal suppression.

    (height,width) = size(img)

    for x = 1:width, y = 1:height
        (c = img[y,x]) == 0 && continue  # For thresholded images

        or = _discretize_angle(gradientangles[y,x],iθ)   # Disretized orientation
        v1, n1 = _interp_offset(img, x, y, xoffs[or], yoffs[or], Ix, Iy, pad)

        if (c > v1) & (c >= n1) # We need to check the value on the other side...
            v2, n2 = _interp_offset(img, x, y, -xoffs[or], -yoffs[or], Ix, Iy, pad)

            if (c > v2) & (c >= n2)  # This is a local maximum.
                                     # Record value in the output image.
                if calc_subpixel
                    # Solve for coefficients of parabola that passes through
                    # [-1, v2]  [0, img] and [1, v1].
                    # v = a*r^2 + b*r + c

                    # c = img[y,x]
                    a = (v1 + v2)/2 - c
                    b = a + c - v2

                    # location where maxima of fitted parabola occurs
                    r = -b/2a
                    location[y,x] = transposed ? Point(y + r*yoffs[or], x + r*xoffs[or]) :
                                                 Point(x + r*xoffs[or], y + r*yoffs[or])

                    if T<:FloatingPoint
                        # Store the interpolated value
                        out[y,x] = a*r^2 + b*r + c
                    else
                        out[y,x] = c
                    end
                else
                    out[y,x] = c
                end
            end
        end
    end

    out
end


# Main function call when subpixel location of edges is not needed
function thin_edges_nonmaxsup!{A<:AbstractArray,B<:AbstractArray}(out::A, img::A, gradientangles::B, border::String="replicate";
                                                                  radius::Float64=1.35, theta=pi/180)
    properties(out) != properties(img) && error("Input and output arrays must have the same properties")
    thin_edges_nonmaxsup_core!(data(out), Array(Point,(0,0)), img, gradientangles, radius, border, theta)
    out
end

function thin_edges_nonmaxsup{T}(img::AbstractArray{T,2}, gradientangles::AbstractArray, border::String="replicate";
                                 radius::Float64=1.35, theta=pi/180)
    (height,width) = size(img)
    out = zeros(T, height, width)
    thin_edges_nonmaxsup_core!(out, Array(Point,(0,0)), img, gradientangles, radius, border, theta)
    copy(img, out)
end

# Main function call when subpixel location of edges is desired
function thin_edges_nonmaxsup_subpix!{A<:AbstractArray, B<:AbstractArray, C<:AbstractArray}(out::A, location::B, img::A, gradientangles::C,
                                     border::String="replicate"; radius::Float64=1.35, theta=pi/180)
    properties(out) != properties(img) && error("Input and output arrays must have the same properties")
    eltype(location) != Point && error("Preallocated subpixel location array/image must have element type Graphics.Point")

    thin_edges_nonmaxsup_core!(data(out), data(location), img, gradientangles, radius, border, theta)
    img, location
end

function thin_edges_nonmaxsup_subpix{T}(img::AbstractArray{T}, gradientangles::AbstractArray,
                                        border::String="replicate"; radius::Float64=1.35, theta=pi/180)
    (height,width) = size(img)
    out = zeros(T, height, width)
    location = zeros(Point, height, width)
    thin_edges_nonmaxsup_core!(out, location, img, gradientangles, radius, border, theta)

    copy(img, out), copy(img, location)
end
